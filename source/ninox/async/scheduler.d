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

static DList!Fiber recycleList;

private Fiber recycleFiber() {
	if (recycleList.empty) {
		return null;
	} else {
		auto f = recycleList.front();
		recycleList.removeFront();
		return f;
	}
}

static if ((void*).sizeof >= 8) {
	// Use an 16Mb stack on 64bit systems.
	enum defaultTaskStackSize = 16*1024*1024;
} else {
	// Use an 512Kb stack on 32bit systems.
	enum defaultTaskStackSite = 512*1024;
}

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

	/// Flag if the scheduler should shutdown
	private bool is_shutdown = false;

	version (linux) {
		private int epoll_fd;
		private enum TIMERFD_FLAG = 0x80_00_00_00;
		private enum TIMERFD_MASK = ~TIMERFD_FLAG;

		private struct epoll_data {
			bool isFd1Timer = false;
			int fd1;

			bool isFd2Timer = false;
			int fd2;

			this(bool isFd1Timer, int fd1) {
				assert((fd1 & TIMERFD_FLAG) == 0, "Cannot create epoll_data: fd1 has TIMERFD_FLAG already set!");
				this.isFd1Timer = isFd1Timer;
				this.fd1 = fd1;
				this.isFd2Timer = false;
				this.fd2 = 0;
			}

			this(bool isFd1Timer, int fd1, bool isFd2Timer, int fd2) {
				assert((fd1 & TIMERFD_FLAG) == 0, "Cannot create epoll_data: fd1 has TIMERFD_FLAG already set!");
				assert((fd2 & TIMERFD_FLAG) == 0, "Cannot create epoll_data: fd2 has TIMERFD_FLAG already set!");
				this.isFd1Timer = isFd1Timer;
				this.fd1 = fd1;
				this.isFd2Timer = isFd2Timer;
				this.fd2 = fd2;
			}

			ulong toData() {
				ulong p1 = this.fd1;
				if (this.isFd1Timer) { p1 |= TIMERFD_FLAG; }

				ulong p2 = this.fd2;
				if (this.isFd2Timer) { p2 |= TIMERFD_FLAG; }

				return cast(ulong) ( (p1 << 32) | p2 );
			}

			static epoll_data fromData(ulong raw) {
				uint p1 = raw >> 32;
				uint p2 = raw & 0xFF_FF_FF_FF;
				return epoll_data(
					(p1 & TIMERFD_FLAG) != 0, p1 & TIMERFD_MASK,
					(p2 & TIMERFD_FLAG) != 0, p2 & TIMERFD_MASK,
				);
			}

			string toString() const @safe pure nothrow {
				import std.conv : to;
				return "epoll_data{ isFd1Timer=" ~ (this.isFd1Timer ? "true" : "false")
					~ ", fd1=" ~ this.fd1.to!string
					~ ", isFd2Timer=" ~ (this.isFd2Timer ? "true" : "false")
					~ ", fd2=" ~ this.fd2.to!string
				~ " }";
			}
		}
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
		this.addIoWaiter(fd, reason, epoll_data(false, fd));
	}

	private void addIoWaiter(immutable int fd, IoWaitReason reason, epoll_data data) {
		io_waiters[fd] = Fiber.getThis();
		version (linux) {
			epoll_event ev;
			ev.events = reason | EPOLLERR | EPOLLHUP | EPOLLRDHUP; // TODO: add EPOLLET?
			ev.data.u64 = data.toData();
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
		if (timeout.total!"hnsecs" < 0) {
			return;
		}

		version (linux) {
			assert((fd & TIMERFD_FLAG) == 0, "FD for addIoWaiter() is invalid; highest (31) bit is set!");

			timespec spec;
			import ninox.async.timeout : timeout_to_timespec;
			timeout_to_timespec(timeout, spec);
			int timerfd = this.addTimeoutWaiter(spec, fd);
			this.addIoWaiter(fd, reason, epoll_data(false, fd, true, timerfd));
		}
	}

	version (linux) {
		void addTimeoutWaiter(ref timespec spec) {
			this.addTimeoutWaiter(spec, 0);
		}

		private int addTimeoutWaiter(ref timespec spec, int extra) {
			int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
			if (fd < 0) {
				import core.stdc.string : strerror;
				import std.string : fromStringz;
				throw new Exception(format("Failed to create timerfd; errno=%d: %s", errno, fromStringz(strerror(errno))));
			}

			itimerspec timer_spec;
			timer_spec.it_value = spec;
			timerfd_settime(fd, TFD_TIMER_ABSTIME, &timer_spec, null);
			this.addIoWaiter(fd, IoWaitReason.read, epoll_data(true, fd, false, extra));
			return fd;
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
	package(ninox.async) void schedule(Fiber f) {
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
		auto f = recycleFiber();
		if (f is null) { f = new Fiber(fn, defaultTaskStackSize); }
		else { f.reset(fn); }
		this.schedule(f, ResumeReason.normal);
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
		auto f = recycleFiber();
		if (f is null) { f = new Fiber(dg, defaultTaskStackSize); }
		else { f.reset(dg); }
		this.schedule(f, ResumeReason.normal);
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

				if (t.fiber.state() == Fiber.State.TERM) {
					// terminated means we can perfectly fine recycle it,
					// since all fibers are always created by us anyway.
					recycleList.insertBack(t.fiber);
				}
			}

			if (this.is_shutdown) {
				break;
			}

			pollEvents();
		}
	}

	package(ninox.async) void shutdown() {
		this.is_shutdown = true;
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
		auto ptr = fd in io_waiters;

		if (ptr is null || *ptr is null) {
			throw new Exception(format("Cannot enqueue io waiter for fd=%d; no such waiter exists...", fd));
		}

		Fiber f = *ptr;
		io_waiters.remove(fd);
		version (linux) {
			epoll_ctl(this.epoll_fd, EPOLL_CTL_DEL, fd, null);
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
	 * Gets the count of io waiters
	 * 
	 * Returns: the count of io waiters
	 */
	public ulong ioWaiterCount() {
		return this.io_waiters.length;
	}

	/**
	 * Handles all io-events
	 *
	 * Uses strategies like epoll under linux to check for io-events and handling them.
	 */
	private void pollEvents() {
		version (linux) {
			epoll_event[64] events;

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

				epoll_data data = epoll_data.fromData(e.data.u64);

				debug (ninoxasync_scheduler_pollEvents) {
					import std.stdio : writeln;
					writeln(format("e.events=%x", cast(uint) flags), " data=", data);
				}

				if (data.isFd1Timer) {
					// close timerfd
					import core.sys.posix.unistd : close;
					close(data.fd1);
				}
				if (data.isFd2Timer) {
					// close timerfd
					import core.sys.posix.unistd : close;
					close(data.fd2);
				}
				if (!data.isFd1Timer && data.isFd2Timer) {
					this.io_waiters.remove(data.fd2);
					epoll_ctl(this.epoll_fd, EPOLL_CTL_DEL, data.fd2, null);
				}

				bool isTimeout = data.isFd1Timer;
				int fd = data.fd1;

				if (flags & EPOLLHUP || flags & EPOLLRDHUP) {
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLHUP/EPOLLRDHUP for fd=", fd);
					}
					this.enqueueIoWaiter(fd, ResumeReason.io_hup);
				}
				else if (flags & EPOLLERR) {
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLERR for fd=", fd);
					}
					this.enqueueIoWaiter(fd, ResumeReason.io_error);
				}
				else if (flags & EPOLLIN) {
					// ready to read
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLIN for fd=", fd);
					}
					this.enqueueIoWaiter(fd, isTimeout ? ResumeReason.io_timeout : ResumeReason.io_ready);
				}
				else if (flags & EPOLLOUT) {
					// ready to write
					debug (ninoxasync_scheduler_pollEvents) {
						import std.stdio : writeln;
						writeln("[ninox.async.scheduler.Scheduler.pollEvents] got EPOLLOUT for fd=", fd);
					}
					this.enqueueIoWaiter(fd, ResumeReason.io_ready);
				}
			}
		}
	}
}
