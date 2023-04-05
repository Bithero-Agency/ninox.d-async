module async.scheduler;

import core.thread : Fiber;
import std.container : DList;
import core.stdc.errno;
import std.format;

version (linux) {
	import core.sys.linux.epoll, core.sys.posix.sys.socket;
}
else {
	static assert(false, "Module " ~ .stringof ~ " dosnt support this OS.");
}

static if (!is(typeof(SOCK_CLOEXEC)))
	enum SOCK_CLOEXEC = 0x80000;

/// The scheduler, the core of everything
class Scheduler {
	/// Queue of all fibers being awaited
	private DList!Fiber queue;

	/// Queue of all fibers waiting for io;
	private Fiber[immutable(int)] io_waiters;

	version (linux) {
		private int epoll_fd;
	}

	this() {
		version(linux) {
			this.epoll_fd = epoll_create1(SOCK_CLOEXEC);
		}
	}

	/// Adds the current fiber to the list of waiters for IO
	void addIoWaiter(immutable int fd) {
		io_waiters[fd] = Fiber.getThis();
		version (linux) {
			epoll_event ev;
			ev.events = EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLRDHUP;
			ev.data.fd = fd;
			epoll_ctl(this.epoll_fd, EPOLL_CTL_ADD, fd, &ev);
		}
	}

	/// Schedules a fiber.
	/// 
	/// Note: The caller must ensure not to schedule the same fiber twice.
	// 
	/// Params:
	///     f = the fiber to be scheduled at a later point in time
	void schedule(Fiber f) {
		this.queue.insertBack(f);
	}

	/// Schedules a function.
	/// 
	/// Note: This creates an $(STDREF Fiber, core,thread) internaly and calls `schedule(Fiber f)`.
	/// 
	/// Params:
	///  fn = the function to schedule
	/// 
	/// In:
	///  fn must not be null
	void schedule(void function() fn)
	in {
		assert(fn);
	}
	do {
		this.schedule(new Fiber(fn));
	}

	/// Schedules a delegate.
	///
	/// Note: This creates an $(STDREF Fiber, core,thread) internaly and calls `schedule(Fiber f)`.
	/// 
	/// Params:
	///  dg = the delegate to schedule
	/// 
	/// In:
	///  dg must not be null
	void schedule(void delegate() dg)
	in {
		assert(dg);
	}
	do {
		this.schedule(new Fiber(dg));
	}

	/// The main loop.
	///
	/// This method is the main eventloop and only returns once all fibers in the scheduler have been completed.
	void loop() {
		// As long as our queue is not empty, we take the front most fiber and call it
		// Thanks to the spin-lock like code in Future.await(), if the work isnt done, we reschedule.
		while (!queue.empty()) {
			Fiber t = queue.front();
			queue.removeFront(1);
			t.call();

			pollEvents();
		}
	}

	/// Reschedules an fiber waiting for io
	/// 
	/// This method tries to get the fiber waiting for io of `fd`, and enqueuing it by calling $(LREF schedule).
	/// 
	/// Params:
	///     fd = the filedescriptor to identifiy the fiber by
	private void enqueueIoWaiter(int fd) {
		if (io_waiters[fd] is null) {
			throw new Exception(format("Cannot enqueue io waiter for fd=%d; no such waiter exists...", fd));
		}

		Fiber f = io_waiters[fd];
		io_waiters[fd] = null;
		this.schedule(f);
	}

	/// Handles all io-events
	///
	/// Uses strategies like epoll under linux to check for io-events and handling them.
	private void pollEvents() {
		version (linux) {
			epoll_event[16] events;
			auto n = epoll_wait(this.epoll_fd, events.ptr, events.length, 0);
			if (n == -1) {
				// THIS IS BAD
				throw new Exception(format("Epoll failed us; pls look into manual. errno=%d", errno));
			}

			foreach (e; events) {
				auto flags = e.events;
				if (flags & EPOLLIN) {
					// ready to read
					this.enqueueIoWaiter(e.data.fd);
				}
				else if (flags & EPOLLOUT) {
					// ready to write
					this.enqueueIoWaiter(e.data.fd);
				}

				if (flags & EPOLLERR) {
					// TODO: some error here...
				}
				if (flags & EPOLLHUP) {
					// TODO: hangup...
				}
			}
		}
	}
}
