/*
 * Copyright (C) 2023-2025 Mai-Lapyst
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
 * Copyright: Copyright (C) 2023-2025 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.scheduler;

import core.thread : Fiber;
import std.container : DList;
import core.time : Duration, dur;

import ninox.std.optional : Optional;
import ninox.async.drivers;
public import ninox.async.drivers.io : IoWaitReason;

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
	enum defaultTaskStackSize = 512*1024;
}

/// The scheduler, the core of everything
class Scheduler {

	private struct Task {
		Fiber fiber;
		ResumeReason reason;
	}

	/// Queue of all fibers being awaited
	private DList!Task queue;

	package(ninox.async) IoDriver io;

	/// Flag if the scheduler should shutdown
	private bool is_shutdown = false;

	private ResumeReason _resume_reason;

	this() {
		this.io = new IoDriver();
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

	package(ninox.async) void schedule(Fiber f, ResumeReason reason) {
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

	pragma(inline) private bool active() {
		return !queue.empty() || io.ioWaiterCount() > 0;
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

			int timeout = 0;
			if (this.queue.empty() && this.io.ioWaiterCount() > 0) {
				// wait infinite on IO when we have no pending tasks in the queue
				timeout = -1;
			}
			this.io.pollEvents();
		}
	}

	package(ninox.async) void shutdown() {
		this.is_shutdown = true;
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

}
