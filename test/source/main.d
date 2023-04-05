import std.stdio : writeln;
import core.thread : Fiber;
import async;

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
