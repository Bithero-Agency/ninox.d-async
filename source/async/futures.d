/*
 * Copyright (C) 2023 Mai-Lapyst
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
 * Copyright: Copyright (C) 2023 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module async.futures;

import core.thread : Fiber;

import async : gscheduler;
import async.utils : Option;

/**
 * Represents some work that can be awaited.
 *
 * To implement this, one has to implement $(LREF Future#getValue) to accqiure the result,
 * and $(LREF Future#isDone) to actually check if the future is resolved. If one donst have a result,
 * extends $(LREF VoidFuture) instead.
 *
 * For an example, see $(D async.timeout.TimeoutFuture).
 *
 * See_Also: $(LREF VoidFuture) a specialization of this class for the `void` type.
 */
abstract class Future(T) {
	/// Returns the value this future resolves to.
	/// Gets called by $(LREF await) once detected that the future has been resolved via $(LREF isDone).
	/// 
	/// Note: Often times this is implemented as an plain getter to an member variable.
	/// 
	/// See_Also: $(LREF await) for the only caller this function should have
	protected abstract T getValue();

	/// Returns true once the future has been resolved.
	/// Gets repeatly called by $(LREF await) to check if the current fiber can continue.
	/// 
	/// Returns: the state if the future has been resolved or not
	/// 
	/// See_Also: $(LREF await) for the only caller this function should have
	protected abstract bool isDone();

	/// Waits on the task until it provides a value,
	/// by using a spin-lock like approach
	/// 
	/// Returns: the value this future produces.
	/// 
	/// See_Also: $(LREF getValue) for the return value and $(LREF isDone) for the check if the future is resolved.
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

/// Future returning nothing
/// 
/// Usefull for custom futures that dosnt produce anything, like $(D async.timeout.TimeoutFuture).
/// 
/// See_Also: $(D async.Future) for the supertype.
abstract class VoidFuture : Future!void {
	protected override void getValue() {}
}

/// Basic future that holds a value
/// For infos how to implement a future, see $(LREF Future).
/// 
/// Note: if you want a `ValueFuture!void`, use $(LREF VoidFuture) instead.
/// 
/// See_Also: $(LREF VoidFuture)
abstract class ValueFuture(T) : Future!T {
	protected T value;

	/// Returns the stored value;
	/// set it in your overwritten $(LREF isDone) method.
	/// 
	/// Return: the stored value
	protected override T getValue() {
		return this.value;
	}
}

private struct CallbackCallable(T) {
	void opAssign(Option!T function() fn) pure nothrow @nogc @safe {
		() @trusted { this.fn = fn; }();
		this.kind = Kind.FN;
	}
	void opAssign(Option!T delegate() dg) pure nothrow @nogc @safe {
		() @trusted { this.dg = dg; }();
		this.kind = Kind.DG;
	}
	Option!T opCall() {
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
		Option!T function() fn;
		Option!T delegate() dg;
	}
}

/// Future that uses an callback to recieve the value and state if it is resolved.
class FnFuture(T) : ValueFuture!T {

	this(Option!T function() fn) nothrow {
		setCallback(fn);
	}

	this(Option!T delegate() dg) nothrow {
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
	final void setCallback(Option!T function() fn) nothrow @nogc {
		cb = fn;
	}
	final void setCallback(Option!T delegate() dg) nothrow @nogc {
		cb = dg;
	}
}
