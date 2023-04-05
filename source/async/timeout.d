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

module async.timeout;

import core.time : Duration;
import async : VoidFuture;

/**
 * A future for a timeout. Use $(LREF timeout) to create it.
 *
 * See_Also: $(LREF timeout) to create a instance of this future
 */
class TimeoutFuture : VoidFuture {
	/// Stores the deadline in hnsecs, after which the future resolves.
	private long deadline;

	/// Creates the future with the given duration
	/// 
	/// sets the deadline by calling $(STDLINK std/datetime/systime/clock.curr_std_time.html, std.datetime.systime.Clock.currStdTime)
	/// and then adding the given duration to it.
	this(Duration dur) {
		import std.datetime.systime : Clock;
		this.deadline = Clock.currStdTime() + dur.total!"hnsecs";
	}

	/// Future is done only when the current timestamp is after the deadline
	protected override bool isDone() {
		import std.datetime.systime : Clock;
		return Clock.currStdTime() >= this.deadline;
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
