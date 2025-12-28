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

module ninox.async.io.socket.accept;

import core.thread : Fiber;
import std.socket : SocketAcceptException, socket_t, Address;

import ninox.async : gscheduler;
import ninox.async.scheduler : IoWaitReason;
import ninox.async.futures : Future;
import ninox.async.io.socket;
import ninox.async.io.errors;

version (Posix) {
    import core.sys.posix.sys.socket;
}
else { static assert(false, "Module " ~ .stringof ~ " not implemented for this OS."); }

// TODO: (arch!=x86 && os==android) => accept4
version (DragonFlyBSD) { version = has_accept4; }
else version (FreeBSD) { version = has_accept4; }
// TODO: fuchsia => accept4
else version (Hurd) { version = has_accept4; }
// TODO: illumos => accept4
else version (linux) { version = has_accept4; }
else version (NetBSD) { version = has_accept4; }
else version (OpenBSD) { version = has_accept4; }
else version (Solaris) { version = has_accept4; }
else version (Cygwin) { version = has_accept4; }

version (has_accept4) {
    extern (C) nothrow @nogc {
        private int accept4(int, sockaddr*, socklen_t*, int);
    }
}

/**
 * Future for accepting sockets from an listening socket.
 * Use $(LREF AsyncSocket.accept) to aqquire an instance of this.
 */
class SocketAcceptFuture : Future!AsyncSocket {
    private AsyncSocket sock;
    private Address* addr_out = null;

    this(AsyncSocket sock, Address* addr_out = null) {
        this.sock = sock;
        this.addr_out = addr_out;
    }

    override AsyncSocket await() {
        auto handle = this.sock.handle();
        gscheduler.io.addIoWaiter(handle, IoWaitReason.read);

        // pause this fiber, we only get called again
        // if there is a socket to accept
        Fiber.yield();

        sockaddr_storage storage;
        socklen_t len = sockaddr_storage.sizeof;

        import core.sys.posix.fcntl;
        version (has_accept4) {
            // TODO: use SOCK_NONBLOCK
            // TODO: use SOCK_CLOEXEC
            auto sock = accept4(
                handle,
                cast(sockaddr*) &storage, &len,
                O_CLOEXEC | O_NONBLOCK
            );
            if (sock < 0) {
                // forwards errno
                throw new SocketAcceptException("Unable to accept socket connection");
            }
        } else {
            static assert(false, "Unsupported target: no support for accept4");
        }

        auto af = this.sock.address_family;
        if (this.addr_out !is null) {
            *this.addr_out = createAddressFrom(af, &storage, len);
        }

        auto res = new AsyncSocket();
        res.sock = cast(socket_t) sock;
        res.address_family = af;
        return res;
    }
}
