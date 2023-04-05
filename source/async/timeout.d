module async.timeout;

import core.time : Duration;
import async : Future;

/// A future for a timeout; uses int as value only because it needs one and 'void' isn't allowed...
class TimeoutFuture : Future!int {
	private long deadline;

	this(Duration dur) {
		import std.datetime : Clock;
		this.deadline = Clock.currStdTime() + dur.total!"hnsecs";
	}

	/// Future is done only when the current timestamp is after the deadline
	protected override bool isDone() {
		import std.datetime : Clock;
		return Clock.currStdTime() >= this.deadline;
	}
}

/// Helper function to make a timeout
TimeoutFuture timeout(Duration dur) {
	return new TimeoutFuture(dur);
}
