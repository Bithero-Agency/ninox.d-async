module async.scheduler;

import core.thread : Fiber;
import std.container : DList;

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
