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
 * This module provides an future for an socket's accept function.
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023-2025 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.io.socket.recv;

import core.thread : Fiber;
import std.socket : SocketFlags;
import std.datetime : Duration;

import ninox.async : gscheduler;
import ninox.async.scheduler : IoWaitReason, ResumeReason;
import ninox.async.futures : Future;
import ninox.async.io.socket;
import ninox.async.io.errors;

version (Posix) {
    import core.sys.posix.sys.socket;
}
else { static assert(false, "Module " ~ .stringof ~ " not implemented for this OS."); }

/**
 * Future for accepting data from an socket.
 * Use $(LREF AsyncSocket.recieve) to aqquire an instance of this.
 */
class SocketRecvFuture : Future!size_t {
    private AsyncSocket sock;
    private const(void[]) buf;
    private Duration read_timeout;
    private SocketFlags flags;
    private bool strict = false;

    /// Reads into a predefined buffer
    this(
        AsyncSocket sock, const(void[]) buf,
        Duration read_timeout = DEFAULT_SOCK_DATA_TIMEOUT,
        SocketFlags flags = SocketFlags.NONE, bool strict = false
    ) {
        this.sock = sock;
        this.buf = buf;
        this.read_timeout = read_timeout;
        this.flags = flags;
    }

    override size_t await() {
        while (true) {
            auto n = recv(
                this.sock.handle(),
                cast(void*) this.buf.ptr, this.buf.length,
                cast(int) this.flags
            );
            if (n == 0) {
                // EOF encountered, no more data!
                return 0;
            }
            else if (n == -1) {
                import core.stdc.errno;
                if (errno == EWOULDBLOCK || errno == EAGAIN) {
                    // Re-enqueue
                    gscheduler.io.addIoWaiter(this.sock.handle(), this.read_timeout, IoWaitReason.read);
                    Fiber.yield();
                    final switch (gscheduler.resume_reason) {
                        case ResumeReason.normal:
                        case ResumeReason.io_ready: {
                            continue;
                        }
                        case ResumeReason.io_timeout: {
                            if (this.strict) {
                                throw new SocketRecvException(SocketRecvException.Kind.timeout);
                            }
                            return 0;
                        }
                        case ResumeReason.io_error: {
                            throw new SocketRecvException(SocketRecvException.Kind.error);
                        }
                        case ResumeReason.io_hup: {
                            throw new SocketRecvException(SocketRecvException.Kind.hup);
                        }
                    }
                    continue;
                }
                else {
                    // Other error
                    // TODO: somehow communicate errno
                    throw new SocketRecvException(SocketRecvException.Kind.error);
                }
            }
            else {
                // n contains the size of the read.
                // TODO: tokio does clear "readiness" on an partial read. Need to investigate why.
                return n;
            }
        }
    }
}
