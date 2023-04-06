import std.stdio : writeln;
import core.thread : Fiber;
import async;

/// Test function 1; waits 5 seconds before ending
void doWork() {
	import core.time;
	writeln("Begin doWork()");
	timeout(seconds(5)).await();
	writeln("End doWork()");
}

/// Test function 2; prints & waits one second 5 times
void otherWork() {
	int count = 0;
	while (count < 5) {
		writeln("do otherWork()...");
		import core.time : seconds;
		timeout(seconds(1)).await();
		count++;
	}
}

void readFile() {
	auto data = readAsync("./big.data").await();
	//writeln(cast(char[]) data);
	writeln("done reading: ", data.length);

	import async.utils : Option;
	auto fut = new FnFuture!int(() {
		import core.time : seconds;
		timeout(seconds(5)).await();
		return Option!int.some(42);
	});
	auto d = fut.await();
	writeln("done fnfut: ", d);
}

/// Main
void main()
{
	gscheduler.schedule(new Fiber(&doWork));
	gscheduler.schedule(new Fiber(&otherWork));
	gscheduler.schedule(new Fiber(&readFile));
	gscheduler.loop();
}
