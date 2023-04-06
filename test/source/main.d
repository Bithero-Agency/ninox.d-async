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

void echoServer() {
	import async.io.socket;
	import std.socket;
	auto l = new AsyncSocket(AddressFamily.INET, SocketType.STREAM);
	l.bind(new InternetAddress("localhost", 8080));
	l.listen();
	while (true) {
		auto sock = l.accept().await();
		writeln("accepted sock: ", sock.remoteAddress);

		char[5] buffer;
		auto n = sock.recieve(buffer).await();
		writeln("got ", n, " bytes of data: ", cast(uint8_t[]) buffer[0 .. n]);
		sock.sendSync(buffer[0 .. n]);

		sock.shutdownSync(SocketShutdown.BOTH);
	}
}

/// Main
void main()
{
	gscheduler.schedule(new Fiber(&doWork));
	gscheduler.schedule(new Fiber(&otherWork));
	gscheduler.schedule(new Fiber(&readFile));
	gscheduler.schedule(&echoServer);
	gscheduler.loop();
}
