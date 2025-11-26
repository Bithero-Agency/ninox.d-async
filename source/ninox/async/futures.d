/*
 * Copyright (C) 2023-2025 Mai-Lapyst
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
 * Module to hold all base future types.
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023-2025 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.futures;

import core.thread : Fiber;

import std.container : DList, SList;
import std.traits : isInstanceOf, TemplateArgsOf, isFunction, isDelegate;
import std.variant : Variant;

import ninox.async : gscheduler;
import ninox.std.optional : Optional;

/**
 * Represents some work that can be awaited.
 * 
 * As startinpoint you can use $(D ninox.async.futures.BasicFuture).
 */
interface Future(T) {
	T await();
}

/**
 * Represents some work that can be awaited.
 *
 * To implement this, one has to implement $(LREF BasicFuture#getValue) to accqiure the result,
 * and $(LREF BasicFuture#isDone) to actually check if the future is resolved. If one donst have a result,
 * extends $(LREF VoidFuture) instead.
 *
 * For an example, see $(D ninox.async.timeout.TimeoutFuture).
 *
 * See_Also: $(LREF VoidFuture) a specialization of this class for the `void` type.
 */
abstract class BasicFuture(T) : Future!T {
	/**
	 * Returns the value this future resolves to.
	 * Gets called by $(LREF await) once detected that the future has been resolved via $(LREF isDone).
	 * 
	 * Note: Often times this is implemented as an plain getter to an member variable.
	 * 
	 * See_Also: $(LREF await) for the only caller this function should have
	 */
	protected abstract T getValue();

	/**
	 * Returns true once the future has been resolved.
	 * Gets repeatly called by $(LREF await) to check if the current fiber can continue.
	 * 
	 * Returns: the state if the future has been resolved or not
	 * 
	 * See_Also: $(LREF await) for the only caller this function should have
	 */
	protected abstract bool isDone();

	/**
	 * Waits on the task until it provides a value,
	 * by using a spin-lock like approach
	 * 
	 * Returns: the value this future produces.
	 * 
	 * See_Also: $(LREF getValue) for the return value and $(LREF isDone) for the check if the future is resolved.
	 */
	T await() {
		while (!this.isDone()) {
			// reschedule the current fiber
			gscheduler.schedule(Fiber.getThis());

			// Yield the current fiber until the task itself is done
			Fiber.yield();
		}
		return this.getValue();
	}
}

/**
 * Future returning nothing
 * 
 * Usefull for custom futures that dosnt produce anything, like $(D ninox.async.timeout.TimeoutFuture).
 * 
 * See_Also: $(D ninox.async.BasicFuture) for the supertype.
 */
abstract class VoidFuture : BasicFuture!void {
	protected override void getValue() {}
}

/**
 * Basic future that holds a value
 * For infos how to implement a future, see $(LREF BasicFuture).
 * 
 * Note: if you want a `ValueFuture!void`, use $(LREF VoidFuture) instead.
 * 
 * See_Also: $(LREF VoidFuture)
 */
abstract class ValueFuture(T) : BasicFuture!T {
	protected T value;

	/**
	 * Returns the stored value;
	 * set it in your overwritten $(LREF isDone) method.
	 * 
	 * Return: the stored value
	 */
	protected override T getValue() {
		return this.value;
	}
}

private struct CallbackCallable(T) {
	void opAssign(Optional!T function() fn) pure nothrow @nogc @safe {
		() @trusted { this.fn = fn; }();
		this.kind = Kind.FN;
	}
	void opAssign(Optional!T delegate() dg) pure nothrow @nogc @safe {
		() @trusted { this.dg = dg; }();
		this.kind = Kind.DG;
	}
	Optional!T opCall() {
		switch (kind) {
			case Kind.FN: return this.fn();
			case Kind.DG: return this.dg();
			default:
				throw new Exception("Invalid callback type for FnFuture...");
		}
	}
private:
	enum Kind { NO, FN, DG };
	Kind kind = Kind.NO;
	union {
		Optional!T function() fn;
		Optional!T delegate() dg;
	}
}

/**
 * Future that uses an callback to recieve the value and state if it is resolved.
 * If you want to return no value (i.e. useing `void`), use $(LREF VoidFnFuture) instead.
 */
class FnFuture(T) : ValueFuture!T {

	this(Optional!T function() fn) nothrow {
		setCallback(fn);
	}

	this(Optional!T delegate() dg) nothrow {
		setCallback(dg);
	}

	protected override bool isDone() {
		auto opt = cb();
		if (opt.isSome()) {
			this.value = opt.take();
			return true;
		}
		return false;
	}

private:
	CallbackCallable!T cb;
	final void setCallback(Optional!T function() fn) nothrow @nogc {
		cb = fn;
	}
	final void setCallback(Optional!T delegate() dg) nothrow @nogc {
		cb = dg;
	}
}

private struct VoidCallbackCallable {
	void opAssign(bool function() fn) pure nothrow @nogc @safe {
		() @trusted { this.fn = fn; }();
		this.kind = Kind.FN;
	}
	void opAssign(bool delegate() dg) pure nothrow @nogc @safe {
		() @trusted { this.dg = dg; }();
		this.kind = Kind.DG;
	}
	bool opCall() {
		switch (kind) {
			case Kind.FN: return this.fn();
			case Kind.DG: return this.dg();
			default:
				throw new Exception("Invalid callback type for FnFuture...");
		}
	}
private:
	enum Kind { NO, FN, DG };
	Kind kind = Kind.NO;
	union {
		bool function() fn;
		bool delegate() dg;
	}
}

/**
 * Future that uses an callback to recieve the state if it is resolved.
 * If you want to return a value, use $(LREF FnFuture) instead.
 */
class VoidFnFuture : VoidFuture {
	this(bool function() fn) nothrow {
		setCallback(fn);
	}

	this(bool delegate() dg) nothrow {
		setCallback(dg);
	}

	protected override bool isDone() {
		return cb();
	}

private:
	VoidCallbackCallable cb;
	final void setCallback(bool function() fn) nothrow @nogc {
		cb = fn;
	}
	final void setCallback(bool delegate() dg) nothrow @nogc {
		cb = dg;
	}
}

/**
 * Runs a function asnycronously
 * 
 * Note:
 *  since delegates arent closures, you need to use $(LREF ninox.async.io.utils.makeClosure) to create a closure.
 * 
 * ---
 * // Boilerplate neccessary to actualy have access to `makeClosure`.
 * import ninox.async.utils : MakeClosure;
 * mixin MakeClosure;
 * 
 * import core.time : seconds;
 * import ninox.async.timeout : timeout;
 * void doSome(int secs) { timeout(seconds(secs)).await(); }
 * 
 * import ninox.async : doAsync;
 * void myFunc() {
 *     int secs = 5;
 *     auto fut = doAsync(makeClosure!"doSome")(secs);
 *     fut.await();
 * }
 * ---
 * 
 * Params:
 *   fn = the function to run
 * 
 * Returns: a future that, when awaited, runs the function
 */
VoidFnFuture doAsync(void function() fn) {
	return new VoidFnFuture(() { fn(); return true; });
}

/**
 * Runs a delegate asnycronously
 * 
 * Note:
 *  since delegates arent closures, you need to use $(LREF ninox.async.io.utils.makeClosure) to create a closure.
 * 
 * ---
 * // Boilerplate neccessary to actualy have access to `makeClosure`.
 * import ninox.async.utils : MakeClosure;
 * mixin MakeClosure;
 * 
 * import core.time : seconds;
 * import ninox.async.timeout : timeout;
 * void doSome(int secs) { timeout(seconds(secs)).await(); }
 * 
 * import ninox.async : doAsync;
 * void myFunc() {
 *     int secs = 5;
 *     auto fut = doAsync(makeClosure!"doSome")(secs);
 *     fut.await();
 * }
 * ---
 * 
 * Params:
 *   dg = the delegate to run
 * 
 * Returns: a future that, when awaited, runs the delegate
 */
VoidFnFuture doAsync(void delegate() dg) {
	return new VoidFnFuture(() { dg(); return true; });
}

/**
 * Runs a function asnycronously
 * 
 * Note:
 *  since delegates arent closures, you need to use $(LREF ninox.async.io.utils.makeClosure) to create a closure.
 * 
 * ---
 * // Boilerplate neccessary to actualy have access to `makeClosure`.
 * import ninox.async.utils : MakeClosure;
 * mixin MakeClosure;
 * 
 * import core.time : seconds;
 * import ninox.async.timeout : timeout;
 * void doSome(int secs) { timeout(seconds(secs)).await(); }
 * 
 * import ninox.async : doAsync;
 * void myFunc() {
 *     int secs = 5;
 *     auto fut = doAsync(makeClosure!"doSome")(secs);
 *     fut.await();
 * }
 * ---
 * 
 * Params:
 *   fn = the function to run
 * 
 * Returns: a future that, when awaited, runs the function and returns the result of it
 */
FnFuture!T doAsync(T)(T function() fn) {
	return new FnFuture!T(() { return Optional!T.some(fn()); });
}

/**
 * Runs a delegate asnycronously
 * 
 * Note:
 *  since delegates arent closures, you need to use $(LREF ninox.async.io.utils.makeClosure) to create a closure.
 * 
 * ---
 * // Boilerplate neccessary to actualy have access to `makeClosure`.
 * import ninox.async.utils : MakeClosure;
 * mixin MakeClosure;
 * 
 * import core.time : seconds;
 * import ninox.async.timeout : timeout;
 * void doSome(int secs) { timeout(seconds(secs)).await(); }
 * 
 * import ninox.async : doAsync;
 * void myFunc() {
 *     int secs = 5;
 *     auto fut = doAsync(makeClosure!"doSome")(secs);
 *     fut.await();
 * }
 * ---
 * 
 * Params:
 *   dg = the delegate to run
 * 
 * Returns: a future that, when awaited, runs the delegate and returns the result of it
 */
FnFuture!T doAsync(T)(T delegate() dg) {
	return new FnFuture!T(() { return Optional!T.some(dg()); });
}

/**
 * Calls some function asyncronously, discarding the result.
 * 
 * Note: do not use expressions such as `doAsync(doWork(some_var))` with this,
 *   since when the future is actually run the *current* value of the variable is used;
 *   not the one when the call was made!
 * ---
 * // Boilerplate neccessary to actualy have access to `makeClosure`.
 * import ninox.async.utils : MakeClosure;
 * mixin MakeClosure;
 * 
 * import core.time : seconds;
 * import ninox.async.timeout : timeout;
 * void doSome(int secs) { timeout(seconds(secs)).await(); }
 * 
 * import ninox.async : doAsync;
 * void myFunc() {
 *     int secs = 5;
 *     auto fut = doAsync(makeClosure!"doSome")(secs);
 *     fut.await();
 * }
 * ---
 * 
 * 
 * Params:
 *  task = lazy expression of the task to do asyncronously
 * 
 * Returns: a future that, when awaited, runs the task supplied
 */
VoidFuture doAsync(T)(lazy T task)
if (is(T == void) && !isFunction!T && !isDelegate!T)
{
	return new VoidFnFuture(() {
		task;
		return true;
	});
}

/**
 * Calls some function asyncronously, capturing the result.
 * 
 * Note: do not use expressions such as `doAsync(doWork(some_var))` with this,
 *   since when the future is actually run the *current* value of the variable is used;
 *   not the one when the call was made!
 * 
 * ---
 * // Boilerplate neccessary to actualy have access to `makeClosure`.
 * import ninox.async.utils : MakeClosure;
 * mixin MakeClosure;
 * 
 * import core.time : seconds;
 * import ninox.async.timeout : timeout;
 * void doSome(int secs) { timeout(seconds(secs)).await(); }
 * 
 * import ninox.async : doAsync;
 * void myFunc() {
 *     int secs = 5;
 *     auto fut = doAsync(makeClosure!"doSome")(secs);
 *     fut.await();
 * }
 * ---
 * 
 * Params:
 *  task = lazy expression of the task to do asyncronously
 * 
 * Returns: a future that, when awaited, runs the task supplied
 */
ValueFuture!T doAsync(T)(lazy T task)
if (!is(T == void) && !isFunction!T && !isDelegate!T)
{
	return new FnFuture!T(() {
		return Optional!T.some(task);
	});
}

/** 
 * Awaits all futures inside the list; all results are discarded.
 * Use $(LREF captureAll) when wanting the results.
 * 
 * Params:
 *  list = list of futures to be awaited; allowed types are $(D std.container.DList) and $(D std.container.SList)
 */
void awaitAllSync(T)(T list)
if (isInstanceOf!(DList, T) || isInstanceOf!(SList, T))
{
	if (list.empty()) {
		return;
	}

	alias A = TemplateArgsOf!T;
	static assert(
		__traits(hasMember, A, "await"),
		"DList has type `" ~ __traits(identifier, A) ~ "` but is not awaitable; implement `await` on it"
	);

	foreach (e; list) {
		e.await();
	}
}

/** 
 * Awaits all futures given; all results are discarded.
 * Use $(LREF captureAll) when wanting the results.
 * 
 * Params:
 *  args = varargs of futures to be awaited
 */
void awaitAllSync(T...)(T args) {
	static if (T.length == 0) {
		return;
	}

	foreach (i, arg; args) {
		import std.conv : to;
		alias A = typeof(arg);
		static assert(
			__traits(hasMember, A, "await"),
			"Argument #" ~ to!string(i) ~ " is of type `" ~ __traits(identifier, A) ~ "` but is not awaitable; implement `await` on it"
		);

		arg.await();
	}
}

/** 
 * Creates a future that when awaited, awaits all futures in the list and captures the results.
 * 
 * Params:
 *   list = list of futures to be awaited; allowed types are $(D std.container.DList) and $(D std.container.SList)
 * 
 * Returns: A future that, when awaited, awaits all futures in the list and captures the results in a $(D std.container.DList)
 */
FnFuture!(DList!R) captureAll(R, T)(T list)
if (isInstanceOf!(DList, T) || isInstanceOf!(SList, T))
{
	alias F = TemplateArgsOf!T;
	static assert(
		__traits(hasMember, F, "await"),
		"DList has type `" ~ __traits(identifier, F) ~ "` but is not awaitable; implement `await` on it"
	);
	return new FnFuture!(DList!R)(() {
		DList!R res;
		foreach (e; list) {
			auto r = e.await();
			res.insertBack(r);
		}
		return Optional!(DList!R).some(res);
	});
}

/** 
 * Creates a future that when awaited, awaits all futures given and captures the results.
 * 
 * Params:
 *   args = varargs of futures to be awaited; allowed types are $(D std.container.DList) and $(D std.container.SList)
 * 
 * Returns: A future that, when awaited, awaits all futures given and captures the results in a $(D std.container.DList)
 */
FnFuture!(DList!R) captureAll(R, T...)(T args)
{
	foreach (i, arg; args) {
		import std.conv : to;
		alias A = typeof(arg);
		static assert(
			__traits(hasMember, A, "await"),
			"Argument #" ~ to!string(i) ~ " is of type `" ~ __traits(identifier, A) ~ "` but is not awaitable; implement `await` on it"
		);
	}
	return new FnFuture!(DList!R)(() {
		import std.stdio;
		DList!R res;
		foreach (arg; args) {
			auto r = arg.await();
			static if (is(R == Variant)) { res.insertBack(Variant(r)); }
			else { res.insertBack(r); }
		}
		return Optional!(DList!R).some(res);
	});
}

/** 
 * Yields the current fiber and ensures that it is re-enqueued to be continued later.
 * 
 * This can be used to create an mandatory point for giving back control to the scheduler so other tasks can run.
 */
void yieldAsync() {
	gscheduler.schedule(Fiber.getThis());
	Fiber.yield();
}
