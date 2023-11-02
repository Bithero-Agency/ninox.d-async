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
 * This module provides asyncronous access to socket IO.
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.io.socket;

import std.socket;
import core.thread : Fiber;

import ninox.async : gscheduler;
import ninox.async.scheduler : IoWaitReason;
import ninox.async.futures : ValueFuture, Future, VoidFuture;

version (Posix) {
    import core.sys.posix.sys.socket, core.sys.posix.sys.ioctl;
}
else { static assert(false, "Module " ~ .stringof ~ " not implemented for this OS."); }

/**
 * Future for accepting sockets from an listening socket.
 * Use $(LREF AsyncSocket.accept) to aqquire an instance of this.
 */
class SocketAcceptFuture : ValueFuture!AsyncSocket {
    private Socket sock;

    this(Socket sock) {
        this.sock = sock;
    }

    protected override bool isDone() {
        gscheduler.addIoWaiter(this.sock.handle(), IoWaitReason.read);

        // pause this fiber, we only get called again
        // if there is a socket to accept
        Fiber.yield();

        auto sock = this.sock.accept();
        this.value = new AsyncSocket(sock);
        return true;
    }
}

static int MAX_SOCK_READBLOCK = 4069;
static int MAX_SOCK_WRITEBLOCK = 4069;

/**
 * Future for accepting data from an socket.
 * Use $(LREF AsyncSocket.recieve) to aqquire an instance of this.
 */
class SocketRecvFuture : ValueFuture!size_t {
    private Socket sock;
    private const(void[]) buf;
    private size_t off = 0;
    private size_t remaining;
    private SocketFlags flags;

    /// Reads into a predefined buffer
    this(Socket sock, const(void[]) buf, SocketFlags flags = SocketFlags.NONE) {
        this.sock = sock;
        this.buf = buf;
        this.remaining = buf.length;
        this.flags = flags;
    }

    protected override bool isDone() {
        // check for data

        int count = 0;
        ioctl(this.sock.handle(), FIONREAD, &count);
        if (count > 0) {
            import std.algorithm : min;
            size_t readsize = min(count, this.remaining, MAX_SOCK_READBLOCK);

            version (Posix) {
                void* ptr = cast(void*) (this.buf.ptr + this.off);
                auto r = recv(
                    this.sock.handle(), ptr, readsize, cast(int) this.flags
                );
                this.remaining -= r;
                this.off += r;
            }

            if (count > readsize && this.remaining > 0) {
                // buffer has still space, and socket has still data, continue next cycle
                gscheduler.addIoWaiter(this.sock.handle(), IoWaitReason.read);
                return false;
            }
            this.value = this.off;
            return true;
        }

        if (this.remaining > 0) {
            gscheduler.addIoWaiter(this.sock.handle(), IoWaitReason.read);
            return false;
        }
        this.value = 0; // TODO: ???
        return true;
    }
}

/**
 * Future for sending data over a socket.
 * Use $(LREF AsyncSocket.send) to aqquire an instance of this.
 */
class SocketSendFuture : VoidFuture {
    private Socket sock;
    private const(void[]) buf;
    private size_t off = 0;
    private size_t remaining;
    private SocketFlags flags;

    this(Socket sock, const(void[]) buf, SocketFlags flags = SocketFlags.NONE) {
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
            gscheduler.addIoWaiter(this.sock.handle(), IoWaitReason.write);
            return false;
        }
        return true;
    }
}

/**
 * Asyncronous variant of $(STDREF Socket, std,socket). Use it like the standard libary variant.
 */
class AsyncSocket {
    private Socket sock;

    /// Use an existing socket.
    this(Socket sock) {
        this.sock = sock;
    }

    /// Creates a socket; see $(STDLINK std/socket/socket.this.html, std,socket.Socket.this).
    this(AddressFamily af, SocketType type, ProtocolType protocol) {
        this(new Socket(af, type, protocol));
    }

    /// ditto
    this(AddressFamily af, SocketType type) {
        this(new Socket(af, type));
    }

    /// ditto
    this(AddressFamily af, SocketType type, scope const(char)[] protocolName) {
        this(new Socket(af, type, protocolName));
    }

    /// Creates a socket; see $(STDLINK std/socket/socket.this.html, std,socket.Socket.this).
    this(const scope AddressInfo info) {
        this(new Socket(info.family, info.type, info.protocol));
    }

    /// Use an existing socket handle.
    this(socket_t sock, AddressFamily af) {
        this(new Socket(sock, af));
    }

    /// Returns the underlaing handle
    Socket getHandle() {
        return this.sock;
    }

    /**
     * Associate a local address with this socket.
     * See $(STDLINK std/socket/socket.bind.html, std.socket.Socket.bind).
     *
     * Params:
     *     addr = the $(STDREF Address, std,socket) to associate this socket with.
     *
     * Throws: $(STDREF SocketOSException, std,socket) when unable to bind the socket.
     *
     * See_Also: $(STDLINK std/socket/socket.bind.html, std.socket.Socket.bind)
     */
    void bind(Address addr) {
        // enable port reuseing before binding
        int enabled = 1;
        setsockopt(
            this.sock.handle(),
            cast(int) SocketOptionLevel.SOCKET,
            SO_REUSEPORT,
            &enabled,
            cast(int) 4 // 4 bytes in one int
        );

        this.sock.bind(addr);
    }

    /// Connects to the given address; see $(STDLINK std/socket/socket.connect.html, std.socket.Socket.connect)
    void connect(Address to) {
        this.sock.connect(to);
    }

    /// Listen for an incomming connection; see $(STDLINK std/socket/socket.listen.html, std.socket.Socket.listen)
    void listen(int backlog = 10) {
        this.sock.listen(backlog);
    }

    /// Accepts an incomming connection; see $(STDLINK std/socket/socket.accept.html, std.socket.Socket.accept)
    Future!AsyncSocket accept() {
        return new SocketAcceptFuture(this.sock);
    }

    /// Shutdowns the socket syncronously
    /// 
    /// See_Also: $(STDLINK std/socket/socket.shutdown.html, std.socket.Socket.shutdown)
    void shutdownSync(SocketShutdown how) {
        this.sock.shutdown(how);
    }

    /// Drops any connections syncronously
    /// Use $(LREF shutdownSync) instead to cleanly shutdown the connection.
    ///
    /// See_Also: $(STDLINK std/socket/socket.close.html, std.socket.Socket.close), $(LREF shutdownSync)
    void closeSync() {
        this.sock.close();
    }

    /// Remote endpoint `Address`.
    /// 
    /// See_Also: $(STDLINK std/socket/socket.remoteAddress.html, std.socket.Socket.remoteAddress).
    @property Address remoteAddress() {
        return this.sock.remoteAddress();
    }

    /// Local endpoint `Address`.
    /// 
    /// See_Also: $(STDLINK std/socket/socket.localAddress.html, std.socket.Socket.localAddress).
    @property Address localAddress() {
        return this.sock.remoteAddress();
    }

    /// Sends data syncronously
    /// 
    /// See_Also: $(STDLINK std/socket/socket.send.html, std.socket.Socket.send).
    ptrdiff_t sendSync(scope const(void)[] buf, SocketFlags flags) {
        return this.sock.send(buf, flags);
    }

    /// Sends data syncronously
    /// 
    /// See_Also: $(STDLINK std/socket/socket.send.html, std.socket.Socket.send).
    ptrdiff_t sendSync(scope const(void)[] buf) {
        return this.sock.send(buf);
    }

    /// Sends data asyncronously
    /// 
    /// Params:
    ///  buf = the buffer to send
    ///  flags = flags for the send operation
    /// 
    /// Return: a future that can be awaited to send the data
    SocketSendFuture send(scope const(void)[] buf, SocketFlags flags = SocketFlags.NONE) {
        return new SocketSendFuture(this.sock, buf, flags);
    }

    /// Sends data syncronously
    /// 
    /// See_Also: $(STDLINK std/socket/socket.sendTo.html, std.socket.Socket.sendTo).
    ptrdiff_t sendToSync(scope const(void)[] buf, SocketFlags flags, Address to) {
        return this.sock.sendTo(buf, flags, to);
    }

    /// Sends data syncronously
    /// 
    /// See_Also: $(STDLINK std/socket/socket.sendTo.html, std.socket.Socket.sendTo).
    ptrdiff_t sendToSync(scope const(void)[] buf, Address to) {
        return this.sock.sendTo(buf, to);
    }

    /// Sends data syncronously
    /// 
    /// See_Also: $(STDLINK std/socket/socket.sendTo.html, std.socket.Socket.sendTo).
    ptrdiff_t sendToSync(scope const(void)[] buf, SocketFlags flags) {
        return this.sock.sendTo(buf, flags);
    }

    /// Sends data syncronously
    /// 
    /// See_Also: $(STDLINK std/socket/socket.sendTo.html, std.socket.Socket.sendTo).
    ptrdiff_t sendToSync(scope const(void)[] buf) {
        return this.sock.sendTo(buf);
    }

    /// Recieves data asyncronously
    /// 
    /// Params:
    ///  buf = the buffer to read into; recieves at max the length of this in bytes
    ///  flags = flags for the recieve operation
    /// 
    /// Return: a future that can be awaited to recieve the amount recived and to make `buf` valid.
    SocketRecvFuture recieve(scope void[] buf, SocketFlags flags = SocketFlags.NONE) {
        return new SocketRecvFuture(this.sock, buf, flags);
    }

    /// Sets the keep alive time & interval
    /// 
    /// See_Also: $(STDLINK std/socket/socket.setKeepAlive.html, std.socket.Socket.setKeepAlive).
    void setKeepAlive(int time, int interval) {
        this.sock.setKeepAlive(time, interval);
    }
}