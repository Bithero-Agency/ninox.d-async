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
 * This module provides asyncronous access to socket IO.
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023-2025 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.io.socket;

import std.socket;
import std.datetime : Duration, dur;
import core.thread : Fiber;

import ninox.async : gscheduler;
import ninox.async.scheduler : IoWaitReason, ResumeReason, TIMEOUT_INFINITY;
import ninox.async.futures : ValueFuture, Future, VoidFuture, yieldAsync;
import ninox.async.io.errors;
import ninox.async.io.socket.accept;
import ninox.async.io.socket.send;
import ninox.async.io.socket.recv;

version (Posix) {
    import core.sys.posix.sys.socket, core.sys.posix.sys.ioctl;
    import core.sys.posix.fcntl;
}
else { static assert(false, "Module " ~ .stringof ~ " not implemented for this OS."); }

Address createAddressFrom(AddressFamily family, sockaddr_storage* storage, size_t len) {
    switch (family) {
        // TODO: AddressFamily.UNIX with sockaddr_un
        case AddressFamily.INET:
            assert(len >= sockaddr_in.sizeof);
            return new InternetAddress(*(cast(sockaddr_in*) storage));
        case AddressFamily.INET6:
            assert(len >= sockaddr_in6.sizeof);
            return new Internet6Address(*(cast(sockaddr_in6*) storage));
        default:
            assert(len >= sockaddr.sizeof);
            auto res = new UnknownAddress();
            *res.name = *(cast(sockaddr*) storage);
            return res;
    }
}

static int MAX_SOCK_READBLOCK = 1024 * 32;
static int MAX_SOCK_WRITEBLOCK = 1024 * 32;

static Duration DEFAULT_SOCK_DATA_TIMEOUT = dur!"seconds"(30);
alias SOCK_TIMEOUT_INFINITY = TIMEOUT_INFINITY;

/**
 * Future for checking for data / activity on a socket.
 * Use $(LREF AsyncSocket.waitForActivity) to aqquire an instance of this.
 */
class SocketActivityFuture : Future!bool {
    private AsyncSocket sock;
    private Duration timeout;

    this(AsyncSocket sock, Duration timeout = DEFAULT_SOCK_DATA_TIMEOUT) {
        this.sock = sock;
        this.timeout = timeout;
    }

    bool await() {
        int count = 0;
        ioctl(this.sock.handle(), FIONREAD, &count);
        if (count > 0) {
            // short circuit here when there's still data to be read
            debug (ninoxasync_socket_activity) {
                import std.stdio : writeln;
                writeln("[SocketActivityFuture] still data in wire-buffer");
            }
            return true;
        }

        gscheduler.io.addIoWaiter(this.sock.handle(), this.timeout, IoWaitReason.read);

        Fiber.yield();

        final switch (gscheduler.resume_reason) {
            case ResumeReason.normal:
            case ResumeReason.io_ready: {
                // no need to read the count again; epoll is only woken up with our fd
                // when there's actual data in the stream; so sending data packets with a
                // length of 0 dosn't acctidentially triggers us!
                debug (ninoxasync_socket_activity) {
                    import std.stdio : writeln;
                    writeln("[SocketActivityFuture] data on wire!");
                }
                return true;
            }

            case ResumeReason.io_timeout: {
                debug (ninoxasync_socket_activity) {
                    import std.stdio : writeln;
                    writeln("[SocketActivityFuture] timeout reached");
                }
                return false;
            }

            case ResumeReason.io_error: {
                throw new SocketActivityException(SocketActivityException.Kind.error);
            }
            case ResumeReason.io_hup: {
                // socket hang up; treat it as no activity available / timeout
                debug (ninoxasync_socket_activity) {
                    import std.stdio : writeln;
                    writeln("[SocketActivityFuture] socket hung up");
                }
                return false;
            }
        }
    }
}

/**
 * Asyncronous variant of $(STDREF Socket, std,socket). Use it like the standard libary variant.
 */
class AsyncSocket {
    package(ninox.async.io.socket) {
        socket_t sock;
        AddressFamily address_family;
    }

    /// Only to be used in `SocketAcceptFuture`.
    package(ninox.async.io.socket) this() {}

    /// Use an existing standardlibrary socket.
    /// Afterwards the underlaying system socket is owned by this type.
    this(ref Socket sock) {
        this.sock = sock.handle();
        this.address_family = sock.addressFamily();
        sock = null;
        version (Posix) {
            fcntl(this.sock, F_SETFD, FD_CLOEXEC); // close on exec
            fcntl(this.sock, F_SETFL, O_NONBLOCK); // non-blocking
        }
    }

    /// Creates a socket from an address family, type and protocol.
    this(AddressFamily af, SocketType type, ProtocolType protocol) {
        this.address_family = af;

        // TODO: use SOCK_NONBLOCK
        // TODO: use SOCK_CLOEXEC
        this.sock = cast(socket_t) socket(af, type | O_NONBLOCK | O_CLOEXEC, protocol);
        // TODO: some systems (darwin) dont have SOCK_ for type of socket(2).
        if (this.sock < 0) {
            throw new SocketOSException("Unable to create socket");
        }
    }

    /// ditto
    this(AddressFamily af, SocketType type) {
        this(af, type, cast(ProtocolType) 0);
    }

    /// ditto
    this(AddressFamily af, SocketType type, scope const(char)[] protocolName) {
        import std.internal.cstring;
        import core.sys.posix.netdb;
        protoent* proto = getprotobyname(protocolName.tempCString());
        if (!proto)
            throw new SocketOSException("Unable to find the protocol");
        this(af, type, cast(ProtocolType) proto.p_proto);
    }

    /// Creates a socket using parameters of the given `AddressInfo`.
    this(const scope AddressInfo info) {
        this(info.family, info.type, info.protocol);
    }

    /// Use an existing socket handle.
    this(socket_t sock, AddressFamily af) {
        this.sock = sock;
        this.address_family = af;
        version (Posix) {
            fcntl(this.sock, F_SETFD, FD_CLOEXEC); // close on exec
            fcntl(this.sock, F_SETFL, O_NONBLOCK); // non-blocking
        }
    }

    /// Returns the underlaing handle
    @property socket_t handle() {
        return this.sock;
    }

    /// Returns the address family of the socket.
    @property AddressFamily addressFamily() {
        return this.address_family;
    }

    /**
     * Associate a local address with this socket.
     *
     * Params:
     *     addr = the $(STDREF Address, std,socket) to associate this socket with.
     *
     * Throws: $(STDREF SocketOSException, std,socket) when unable to bind the socket.
     */
    void bind(Address addr) {
        // enable port reuseing before binding
        int enabled = 1;
        setsockopt(
            this.sock,
            cast(int) SocketOptionLevel.SOCKET,
            SO_REUSEPORT,
            &enabled,
            cast(int) 4 // 4 bytes in one int
        );

        if (.bind(this.sock, addr.name, addr.nameLen) < 0) {
            throw new SocketOSException("Unable to bind socket");
        }
    }

    /**
     * Connects to the given address.
     * 
     * Params:
     *     addr = the $(STDREF Address, std,socket) to connect to.
     * 
     * Throws: $(STDREF SocketOSException, std,socket) when unable to connect the socket.
     */
    void connect(Address to) {
        if (.connect(sock, to.name, to.nameLen) < 0) {
            throw new SocketOSException("Unable to connect socket");
        }
    }

    /**
     * Listen for an incomming connection.
     * 
     * Params:
     *   backlog = backlog hint for the kernel on how many connections should be waited on until
     *             the kernel starts rejecting connection attempts.
     */
    void listen(int backlog = 10) {
        if (.listen(this.sock, backlog) < 0) {
            throw new SocketOSException("Unable to listen on socket");
        }
    }

    /**
     * Accepts an incomming connection.
     * 
     * Note: socket must first be set to be an bound to an address using $(LREF bind) as well as
     *       set to the be in listen-mode via $(LREF listen).
     */
    Future!AsyncSocket accept() {
        return new SocketAcceptFuture(this);
    }

    /** 
     * Accepts an incomming connection like $(LREF accept), but also captures the
     * remote address given back by the `accept` syscall.
     * 
     * Params:
     *   address = reference to the address to be set.
     */
    Future!AsyncSocket accept(ref Address address) {
        return new SocketAcceptFuture(this, &address);
    }

    /**
     * Shutdowns the socket syncronously
     * 
     * See_Also: $(STDLINK std/socket/socket.shutdown.html, std.socket.Socket.shutdown)
     */
    void shutdownSync(SocketShutdown how) {
        .shutdown(this.sock, cast(int) how);
    }

    /**
     * Drops any connections syncronously
     * Use $(LREF shutdownSync) instead to cleanly shutdown the connection.
     *
     * See_Also: $(LREF shutdownSync)
     */
    void closeSync() {
        import core.sys.posix.unistd;
        close(this.sock);
        this.sock = cast(socket_t) -1;
    }

    /**
     * Remote endpoint `Address`.
     */
    @property Address remoteAddress() {
        sockaddr_storage storage;
        socklen_t len = sockaddr_storage.sizeof;
        if (.getpeername(this.sock, cast(sockaddr*) &storage, &len)) {
            throw new SocketOSException("Unable to obtain remote socket address");
        }
        return createAddressFrom(this.address_family, &storage, len);
    }

    /// ditto
    @property pragma(inline) Address peerAddress() {
        return this.remoteAddress;
    }

    /**
     * Local endpoint `Address`.
     */
    @property Address localAddress() {
        sockaddr_storage storage;
        socklen_t len = sockaddr_storage.sizeof;
        if (.getsockname(this.sock, cast(sockaddr*) &storage, &len)) {
            throw new SocketOSException("Unable to obtain local socket address");
        }
        return createAddressFrom(this.address_family, &storage, len);
    }

    /**
     * Sends data asyncronously
     * 
     * Params:
     *  buf = the buffer to send
     *  flags = flags for the send operation
     * 
     * Return: a future that can be awaited to send the data
     */
    SocketSendFuture send(scope const(void)[] buf, SocketFlags flags = SocketFlags.NONE) {
        return new SocketSendFuture(this, buf, flags);
    }

    /**
     * Recieves data asyncronously
     * 
     * Params:
     *  buf = the buffer to read into; recieves at max the length of this in bytes
     *  read_timeout = timeout after which the data that was read up until that point should be returned; default: 30 seconds
     *  flags = flags for the recieve operation
     * 
     * Return: a future that can be awaited to recieve the amount recived and to make `buf` valid.
     */
    SocketRecvFuture recieve(scope void[] buf, Duration read_timeout = DEFAULT_SOCK_DATA_TIMEOUT, SocketFlags flags = SocketFlags.NONE) {
        return new SocketRecvFuture(this, buf, read_timeout, flags);
    }

    /**
     * Much like $(D recieve) but without any timeout;
     * equivalent to calling $(D recieve(buf, SOCK_TIMEOUT_INFINITY, flags)).
     * 
     * Params:
     *  buf = the buffer to read into; recieves at max the length of this in bytes
     *  flags = flags for the recieve operation
     * 
     * Return: a future that can be awaited to recieve the amount recived and to make `buf` valid.
     */
    SocketRecvFuture recieveNoTimeout(scope void[] buf, SocketFlags flags = SocketFlags.NONE) {
        return this.recieve(buf, SOCK_TIMEOUT_INFINITY, flags);
    }

    /**
     * Much like $(D recieve) but instead of returning after a timeout, it instead throws a $(D ninox.async.io.socket.SocketRecvException).
     *
     * Params:
     *  buf = the buffer to read into; recieves at max the length of this in bytes
     *  read_timeout = timeout after which the data that was read up until that point should be returned; default: 30 seconds
     *  flags = flags for the recieve operation
     * 
     * Return: a future that can be awaited to recieve the amount recived and to make `buf` valid.
     */
    SocketRecvFuture recieveStrictTimeout(scope void[] buf, Duration read_timeout = DEFAULT_SOCK_DATA_TIMEOUT, SocketFlags flags = SocketFlags.NONE) {
        return new SocketRecvFuture(this, buf, read_timeout, flags, true);
    }

    /** 
     * Creates a future that, when awaited, waits for any IO activity of the socket
     * 
     * Params:
     *   timeout = the timeout for waiting got activity
     * 
     * Returns: true if activity was detected; false if no activity occured before timeout ran out
     */
    Future!bool waitForActivity(Duration timeout = DEFAULT_SOCK_DATA_TIMEOUT) {
        return new SocketActivityFuture(this, timeout);
    }

    /**
     * Sets the keep alive time & interval
     */
    void setKeepAlive(int time, int interval) {
        throw new Exception("NIY");
    }

    /** 
     * Set a socket option.
     */
    pragma(inline) void setOption(SocketOptionLevel level, SocketOption option, scope void[] value) @trusted {
        if (.setsockopt(this.sock, cast(int) level, cast(int) option, value.ptr, cast(uint) value.length) < 0) {
            throw new SocketOSException("Unable to set socket option");
        }
    }

    /** 
     * Common case for setting integer and boolean options.
     */
    pragma(inline) void setOption(SocketOptionLevel level, SocketOption option, int32_t value) @trusted {
        this.setOption(level, option, (&value)[0 .. 1]);
    }

    /** 
     * Set the linger option.
     */
    pragma(inline) void setOption(SocketOptionLevel level, SocketOption option, Linger value) @trusted {
        this.setOption(level, option, (&value.clinger)[0 .. 1]);
    }

    /**
     * Sets a timeout (duration) option, i.e. `SocketOption.SNDTIMEO` or
     * `RCVTIMEO`. Zero indicates no timeout.
     */
    pragma(inline) void setOption(SocketOptionLevel level, SocketOption option, Duration value) @trusted {
        this.setOption(level, option, value);
    }

    pragma(inline) @property void blocking(bool val) {
        if (val)
            throw new Exception("Cannot set AsnycSocket into blocking mode!");
    }

    pragma(inline) @property void tcpnodelay(bool val) {
        this.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, val);
    }

    pragma(inline) @property void reuseaddr(bool val) {
        this.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, val);
    }

}