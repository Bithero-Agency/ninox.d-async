import std.stdio : writeln;
import core.thread : Fiber;
import ninox.async;

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

	import ninox.std.optional : Optional;
	auto fut = new FnFuture!int(() {
		import core.time : seconds;
		timeout(seconds(5)).await();
		return Optional!int.some(42);
	});
	auto d = fut.await();
	writeln("done fnfut: ", d);
}

void echoServer() {
	import ninox.async.io.socket;
	import std.socket;
	import std.datetime : dur;
	auto l = new AsyncSocket(AddressFamily.INET, SocketType.STREAM);
	l.bind(new InternetAddress("localhost", 8080));
	l.listen();
	while (true) {
		auto sock = l.accept().await();
		writeln("accepted sock: ", sock.remoteAddress);

		char[5] buffer;
		auto n = sock.recieveStrictTimeout(buffer, dur!"seconds"(3)).await();
		writeln("got ", n, " bytes of data: ", cast(uint8_t[]) buffer[0 .. n]);
		sock.send(buffer[0 .. n]).await();

		sock.shutdownSync(SocketShutdown.BOTH);
		sock.closeSync();
	}
}

int doTimeout(int secs) {
	import core.time;
	writeln("Start doTimeout for ", secs, " seconds");
	timeout(seconds(secs)).await();
	writeln("End doTimeout for ", secs, " seconds");
	return secs * 2;
}
long doTimeout2(int secs) {
	import core.time;
	writeln("Start doTimeout for ", secs, " seconds");
	timeout(seconds(secs)).await();
	writeln("End doTimeout for ", secs, " seconds");
	return secs * 2;
}

import ninox.async.utils : MakeClosure;
mixin MakeClosure;

void testAsyncFn() {
	import std.container : DList;
	import ninox.async : doAsync;
	DList!(ValueFuture!int) futures;
	int[] secs = [5, 8, 10];
	foreach (sec; secs) {
		auto cl = makeClosure!"doTimeout"(sec);
		auto fut = doAsync(cl);
		futures.insertBack(fut);
	}
	import std.variant : Variant;
	auto res = captureAll!Variant( doAsync(doTimeout(5)), doAsync(doTimeout2(8)) ).await();
	foreach(r; res) { writeln(" - ", r); }
}

/// Main
void main()
{
	gscheduler.schedule(new Fiber(&doWork));
	//gscheduler.schedule(new Fiber(&otherWork));
	//gscheduler.schedule(new Fiber(&readFile));
	//gscheduler.schedule(&testAsyncFn);
	//gscheduler.schedule(&echoServer);
	gscheduler.loop();
}
