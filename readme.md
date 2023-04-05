# MiniAsync

A small asyncronous framework for everyone.

## License

The code in this repository is licensed under AGPL-3.0-or-later; for more details see the `LICENSE` file in the repository.

## Getting started

This library aims to have an small but complete asyncronous solution for dlang programs.

It's based around `Furure`'s and `await`; a simple example would be:
```d
import core.time : seconds;
import async.timeout : timeout;
timeout(seconds(5)).await();
```
Here `timeout` had a signature of `TimeoutFuture timeout(Duration dur);` where `TimeoutFuture` extends `async.Future(T)`.
The future itselv implements `T await();` which can be called to await the future and get the result; in out case here `void` since
a timeout dosnt produce a value.

To use futures, you must be in an fiber, and to achive that you simply schedule your function:
```
import async : gscheduler;
gscheduler.schedule(&someFunc);
```

Your `main`-function also should call `gscheduler.loop();` before it's end to actually start the whole eventloop.

## Roadmap

- improve handling / distinction of io-events
- improve way we handle futures: would like to get rid of spin-lock like codeflow
- add more io futures:
  - chunked file io
  - socket based io
- add signalhandlers for `SIGTERM` and `SIGINT`
- support `io_uring` under linux
- support more platforms like windows and osx
- reduce boilerplate / add an `async main`.
- add thread-pool support
- add more library features such as arbitary streams