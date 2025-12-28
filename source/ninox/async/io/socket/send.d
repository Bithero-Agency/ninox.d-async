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
 * This module provides an future for an socket's send function.
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023-2025 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.io.socket.send;

import core.thread : Fiber;
import std.socket : SocketFlags;

import ninox.async : gscheduler;
import ninox.async.scheduler : IoWaitReason, ResumeReason;
import ninox.async.futures : VoidFuture;
import ninox.async.io.socket;
import ninox.async.io.errors;

version (Posix) {
    import core.sys.posix.sys.socket;
}
else { static assert(false, "Module " ~ .stringof ~ " not implemented for this OS."); }

/**
 * Future for sending data over a socket.
 * Use $(LREF AsyncSocket.send) to aqquire an instance of this.
 */
class SocketSendFuture : VoidFuture {
    private AsyncSocket sock;
    private const(void[]) buf;
    private size_t off = 0;
    private size_t remaining;
    private SocketFlags flags;

    this(AsyncSocket sock, const(void[]) buf, SocketFlags flags = SocketFlags.NONE) {
        this.sock = sock;
        this.buf = buf;
        this.remaining = buf.length;
        this.flags = flags;
    }

    protected override bool isDone() {
        import std.algorithm : min;
        int writesize = min(this.remaining, MAX_SOCK_WRITEBLOCK);

        version (Posix) {
            void* ptr = cast(void*) (this.buf.ptr + this.off);
            auto r = send(
                this.sock.handle(), ptr, writesize, cast(int) this.flags
            );
            this.remaining -= r;
            this.off += r;
        }

        if (this.remaining > 0) {
            gscheduler.io.addIoWaiter(this.sock.handle(), IoWaitReason.write);
            return false;
        }
        return true;
    }

    override void await() {
        while (!this.isDone()) {
            // reschedule already done by isDone() via addIoWaiter

            // Yield the current fiber until the task itself is done
            Fiber.yield();

            // check reason why we resume:
            final switch (gscheduler.resume_reason) {
                case ResumeReason.normal:
                case ResumeReason.io_ready: {
                    continue;
                }

                case ResumeReason.io_timeout: {
                    // if (this.strict) {
                    throw new SocketSendException(SocketSendException.Kind.timeout);
                    // }
                    // return;
                }

                case ResumeReason.io_error: {
                    throw new SocketSendException(SocketSendException.Kind.error);
                }
                case ResumeReason.io_hup: {
                    throw new SocketSendException(SocketSendException.Kind.hup);
                }
            }
        }
        return this.getValue();
    }
}
