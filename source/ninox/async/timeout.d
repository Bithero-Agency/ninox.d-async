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
 * This module provides the most simplest future: a timeout
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.timeout;

import core.time : Duration, dur, convert;
import ninox.async.futures : VoidFuture;
import ninox.async : gscheduler;
import core.thread : Fiber;

version (linux) {
	import core.sys.linux.timerfd;
}
else {
	static assert(false, "Module " ~ .stringof ~ " dosnt support this OS.");
}

version (linux) {
	package (ninox.async) void timeout_to_timespec(ref Duration timeout, ref timespec spec) {
		clock_gettime(CLOCK_MONOTONIC, &spec);
		long sec = timeout.total!"seconds";
		spec.tv_sec += sec;
		spec.tv_nsec += timeout.total!"nsecs" - convert!("seconds", "nsecs")(sec);
	}
}

/**
 * A future for a timeout. Use $(LREF timeout) to create it.
 *
 * See_Also: $(LREF timeout) to create a instance of this future
 */
class TimeoutFuture : VoidFuture {

	version (linux) {
		private timespec spec;
	}

	/**
	 * Creates the future with the given duration
	 * 
	 * sets the deadline by calling $(STDLINK std/datetime/systime/clock.curr_std_time.html, std.datetime.systime.Clock.currStdTime)
	 * and then adding the given duration to it.
	 */
	this(Duration timeout) {
		version (linux) {
			timeout_to_timespec(timeout, this.spec);
		}
	}

	/// Future is done only when the current timestamp is after the deadline
	protected override bool isDone() {
		version (linux) {
			gscheduler.addTimeoutWaiter(this.spec);
			Fiber.yield();
			return true;
		}
	}
}

/**
 * Creates a future which resolves only after the given amount of time has passed.
 *
 * Example:
 * ---
 * import core.time : seconds;
 * timeout(seconds(5)).await();
 * ---
 *
 * Params:
 *     dur = duration the timeout should take
 *
 * Return: A future resolving only after a certain amount of time has passed.
 *
 * See_Also: $(LREF TimeoutFuture) for the future returned
 */
TimeoutFuture timeout(Duration dur) {
	return new TimeoutFuture(dur);
}
