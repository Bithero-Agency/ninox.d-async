module async;

import core.thread : Fiber;

public import async.scheduler;
public import async.timeout;

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
