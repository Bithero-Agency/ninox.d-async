module main;

import std.stdio : writeln;
import core.thread : Fiber, Thread;
import std.container : DList;
import core.time : Duration;

/// Represents some work that can be awaited
abstract class Future(T) {
	private T value;

	protected abstract bool isDone();

	/// Waits on the task until it provides a value,
	/// by using a spin-lock like approach
	T await() {
		while (!this.isDone()) {
			// reschedule the current fiber
			gscheduler.schedule(Fiber.getThis());

			// Yield the current fiber until the task itself is done
			Fiber.yield();
		}
		return this.value;
	}
}

/// The global scheduler!
Scheduler gscheduler;

/// Initializes a global scheduler
static this() {
	gscheduler = new Scheduler();
}

/// The scheduler, the core of everything
class Scheduler {
	/// Queue of all fibers being awaited
	private DList!Fiber queue;

	/// Schedules a fiber
	void schedule(Fiber f) {
		this.queue.insertBack(f);
	}

	/// The main loop
	void loop() {
		// As long as our queue is not empty, we take the front most fiber and call it
		// Thanks to the spin-lock like code in Future.await(), if the work isnt done, we reschedule.
		while (!queue.empty()) {
			Fiber t = queue.front();
			queue.removeFront(1);
			t.call();
		}
	}
}

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

/// Test function 1; waits 5 seconds before ending
void doWork() {
	import core.time;
	writeln("Begin doWork()");
	int _ = timeout(seconds(5)).await();
	writeln("End doWork()");
}

/// Test function 2; prints & waits one second 5 times
void otherWork() {
	int count = 0;
	while (count < 5) {
		writeln("do otherWork()...");
		import core.time;
		int _ = timeout(seconds(1)).await();
		count++;
	}
}

/// Main
void main()
{
	gscheduler.schedule(new Fiber(&doWork));
	gscheduler.schedule(new Fiber(&otherWork));
	gscheduler.loop();
}
