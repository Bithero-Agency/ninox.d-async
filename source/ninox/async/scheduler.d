/*
 * Copyright (C) 2023 Mai-Lapyst
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 * 
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/** 
 * The main component: the scheduler!
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.scheduler;

import core.thread : Fiber;
import std.container : DList;
import core.stdc.errno;
import std.format;
import std.datetime : Clock;
import core.time : Duration, dur;

import ninox.std.optional : Optional;

version (linux) {
	import core.sys.linux.epoll, core.sys.posix.sys.socket, core.sys.linux.timerfd;
}
else {
	static assert(false, "Module " ~ .stringof ~ " dosnt support this OS.");
}

static if (!is(typeof(SOCK_CLOEXEC)))
	enum SOCK_CLOEXEC = 0x80000;

/// Enum to specify for what IO operation to wait for
enum IoWaitReason {
	read_write = EPOLLIN | EPOLLOUT,
	read = EPOLLIN,
	write = EPOLLOUT,
}

/// Enum to specify why a Fiber was resumed
enum ResumeReason {
	normal,
	io_ready,
	io_timeout,
	io_error,
	io_hup,
}

static Duration TIMEOUT_INFINITY = dur!"hnsecs"(-1);

/// The scheduler, the core of everything
class Scheduler {

	private struct Task {
		Fiber fiber;
		ResumeReason reason;
	}

	/// Queue of all fibers being awaited
	private DList!Task queue;

	/// Queue of all fibers waiting for io;
	private Fiber[immutable(int)] io_waiters;

	version (linux) {
		private int epoll_fd;
		private enum TIMERFD_FLAG = 0x80_00_00_00;
		private enum TIMERFD_MASK = ~TIMERFD_FLAG;
	}

	private ResumeReason _resume_reason;

	this() {
		version(linux) {
			this.epoll_fd = epoll_create1(SOCK_CLOEXEC);
		}
	}

	/**
	 * Retrieves the current resume reason
	 * 
	 * Returns: the reason why the a Fiber was resumed
	 */
	@property ResumeReason resume_reason() {
		return this._resume_reason;
	}

	/**
	 * Adds the current fiber to the list of waiters for IO
	 * 
	 * Params:
	 *     fd = the fd to wait for
	 *     reason = reason for the wait; prevents wakeup for events not needed
	 */
	void addIoWaiter(immutable int fd, IoWaitReason reason = IoWaitReason.read_write) {
		this.addIoWaiter(fd, reason, 0);
	}

	private void addIoWaiter(immutable int fd, IoWaitReason reason, int extra) {
		io_waiters[fd] = Fiber.getThis();
		version (linux) {
			epoll_event ev;
			ev.events = reason | EPOLLERR | EPOLLHUP | EPOLLRDHUP; // TODO: add EPOLLET?
			ev.data.u64 = ((cast (long) extra) << 32) | fd;
			epoll_ctl(this.epoll_fd, EPOLL_CTL_ADD, fd, &ev);
		}
	}

	/**
	 * Adds the current fiber to the list of waiters for IO
	 * 
	 * Params:
	 *     fd = the fd to wait for
	 *     timeout = timeout for the IO operation before resuming fiber
	 *     reason = reason for the wait; prevents wakeup for events not needed
	 */
	void addIoWaiter(immutable int fd, Duration timeout, IoWaitReason reason = IoWaitReason.read_write) {
		this.addIoWaiter(fd, reason);

		if (timeout.total!"hnsecs" < 0) {
			return;
		}

		version (linux) {
			assert((fd & TIMERFD_FLAG) != 0, "FD for addIoWaiter() is invalid; highest (31) bit is set!");

			timespec spec;
			import ninox.async.timeout : timeout_to_timespec;
			timeout_to_timespec(timeout, spec);
			this.addTimeoutWaiter(spec, fd);
		}
	}

	version (linux) {
		void addTimeoutWaiter(ref timespec spec) {
			this.addTimeoutWaiter(spec, 0);
		}

		private void addTimeoutWaiter(ref timespec spec, int extra) {
			int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
			itimerspec timer_spec;
			timer_spec.it_value = spec;
			timerfd_settime(fd, TFD_TIMER_ABSTIME, &timer_spec, null);
			this.addIoWaiter(fd, IoWaitReason.read, extra | TIMERFD_FLAG);
		}
	}

	/**
	 * Schedules a fiber.
	 * 
	 * Note: The caller must ensure not to schedule the same fiber twice.
	 *
	 * Params:
	 *     f = the fiber to be scheduled at a later point in time
	 */
	void schedule(Fiber f) {
		this.schedule(f, ResumeReason.normal);
	}

	private void schedule(Fiber f, ResumeReason reason) {
		this.queue.insertBack(Task(f, reason));
	}

	/**
	 * Schedules a function.
	 * 
	 * Note: This creates an $(STDREF Fiber, core,thread) internaly and calls `schedule(Fiber f)`.
	 * 
	 * Params:
	 *  fn = the function to schedule
	 * 
	 * In:
	 *  fn must not be null
	 */
	void schedule(void function() fn)
	in {
		assert(fn);
	}
	do {
		this.schedule(new Fiber(fn));
	}

	/**
	 * Schedules a delegate.
	 *
	 * Note: This creates an $(STDREF Fiber, core,thread) internaly and calls `schedule(Fiber f)`.
	 * 
	 * Params:
	 *  dg = the delegate to schedule
	 * 
	 * In:
	 *  dg must not be null
	 */
	void schedule(void delegate() dg)
	in {
		assert(dg);
	}
	do {
		this.schedule(new Fiber(dg));
	}

	private bool active() {
		return !queue.empty() || io_waiters.length > 0;
	}

	/**
	 * The main loop.
	 *
	 * This method is the main eventloop and only returns once all fibers in the scheduler have been completed.
	 */
	void loop() {
		// As long as our queue is not empty, we take the front most fiber and call it
		// Thanks to the spin-lock like code in Future.await(), if the work isnt done, we reschedule.
		while (this.active()) {
			if (!this.queue.empty()) {
				Task t = this.queue.front();
				this.queue.removeFront(1);
				if (t.fiber.state() != Fiber.State.TERM) {
					this._resume_reason = t.reason;
					t.fiber.call();
				}
			}

			pollEvents();
		}
	}

	/**
	 * Reschedules an fiber waiting for io
	 * 
	 * This method tries to get the fiber waiting for io of `fd`, and enqueuing it by calling $(LREF schedule).
	 * 
	 * Params:
	 *     fd = the filedescriptor to identifiy the fiber by
	 *     reason = the reason why the IoWaiter was enqueued
	 */
	private void enqueueIoWaiter(int fd, ResumeReason reason) {
		if (io_waiters[fd] is null) {
			throw new Exception(format("Cannot enqueue io waiter for fd=%d; no such waiter exists...", fd));
		}

		Fiber f = io_waiters[fd];
		io_waiters.remove(fd);
		version (linux) {
			epoll_event ev;
			ev.data.fd = fd;
			epoll_ctl(this.epoll_fd, EPOLL_CTL_DEL, fd, &ev);
		}
		this.schedule(f, reason);
	}

	/**
	 * Gets the size of the queue
	 * 
	 * Note: since the queue is a $(REF std.container.dlist.DList), this operation takes `O(n)` time.
	 * 
	 * Returns: the size of the queue
	 */
	public int queueSize() {
		int size = 0;
		foreach (_; this.queue) {
			size += 1;
		}
		return size;
	}

	/**
	 * Handles all io-events
	 *
	 * Uses strategies like epoll under linux to check for io-events and handling them.
	 */
	private void pollEvents() {
		version (linux) {
			epoll_event[16] events;

			int timeout = 0;
			if (this.queue.empty() && io_waiters.length > 0) {
				// wait infinite on IO when we have no pending tasks in the queue
				timeout = -1;
			}

			auto n = epoll_wait(this.epoll_fd, events.ptr, events.length, timeout);
			if (n == -1) {
				import core.stdc.errno;
				if (errno == EINTR) {
					// this happens when for example a breakpoint is set in gdb or similar
					// we simply ignore it and continue like normal
					return;
				}

				// THIS IS BAD
				import core.stdc.string : strerror;
				import std.string : fromStringz;
				throw new Exception(format("Epoll failed us; pls look into manual. errno=%d: %s", errno, fromStringz(strerror(errno))));
			}

			foreach (i; 0 .. n) {
				auto e = events[i];
				auto flags = e.events;

				int fd = cast(int) (e.data.u64 & 0xffffffff);
				int extra = cast(int) (e.data.u64 >> 32);
				bool isTimer = (extra & TIMERFD_FLAG) != 0;
				extra = extra & TIMERFD_MASK;

				if (isTimer) {
					// close timerfd
					import core.sys.posix.unistd : close;
					close(fd);
				}

				if (extra != 0) {
					// if extra is non-zero; we have an timeout timerfd in fd, and extra the io-fd assosicated
					// with it. delete io-waiter here so we dont trigger the fiber in the future
					this.io_waiters.remove(extra);
					epoll_event ev;
					ev.data.u64 = e.data.u64;
					epoll_ctl(this.epoll_fd, EPOLL_CTL_DEL, extra, &ev);
				}

				if (flags & EPOLLERR) {
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLERR for fd=", fd, " extra=", extra);
					}
					this.enqueueIoWaiter(fd, ResumeReason.io_error);
				}
				else if (flags & EPOLLHUP) {
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLHUP for fd=", fd, " extra=", extra);
					}
					this.enqueueIoWaiter(fd, ResumeReason.io_hup);
				}
				else if (flags & EPOLLIN) {
					// ready to read
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLIN for fd=", fd, " extra=", extra);
					}
					this.enqueueIoWaiter(fd, extra != 0 ? ResumeReason.io_timeout : ResumeReason.io_ready);
				}
				else if (flags & EPOLLOUT) {
					// ready to write
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLOUT for fd=", fd, " extra=", extra);
					}
					this.enqueueIoWaiter(fd, ResumeReason.io_ready);
				}
			}
		}
	}
}
