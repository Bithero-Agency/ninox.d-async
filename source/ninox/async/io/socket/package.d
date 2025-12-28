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

version (Posix) {
    import core.sys.posix.sys.socket, core.sys.posix.sys.ioctl;
    import core.sys.posix.fcntl;
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

private Address createAddressFrom(AddressFamily family, sockaddr_storage* storage, size_t len) {
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

/**
 * Future for accepting sockets from an listening socket.
 * Use $(LREF AsyncSocket.accept) to aqquire an instance of this.
 */
class SocketAcceptFuture : Future!AsyncSocket {
    private AsyncSocket sock;

    this(AsyncSocket sock) {
        this.sock = sock;
    }

    override AsyncSocket await() {
        auto handle = this.sock.handle();
        gscheduler.io.addIoWaiter(handle, IoWaitReason.read);

        // pause this fiber, we only get called again
        // if there is a socket to accept
        Fiber.yield();

        sockaddr addr;
        socklen_t addr_len = sockaddr.sizeof;

        import core.sys.posix.fcntl;
        version (has_accept4) {
            // TODO: use SOCK_NONBLOCK
            // TODO: use SOCK_CLOEXEC
            auto sock = accept4(
                handle,
                &addr, &addr_len,
                O_CLOEXEC | O_NONBLOCK
            );
            if (sock < 0) {
                // forwards errno
                throw new SocketAcceptException("Unable to accept socket connection");
            }
        } else {
            static assert(false, "Unsupported target: no support for accept4");
        }

        // TODO: allow to return the socket address or somehow store it...

        auto res = new AsyncSocket();
        res.sock = cast(socket_t) sock;
        res.address_family = this.sock.addressFamily;
        return res;
    }
}

static int MAX_SOCK_READBLOCK = 1024 * 32;
static int MAX_SOCK_WRITEBLOCK = 1024 * 32;

static Duration DEFAULT_SOCK_DATA_TIMEOUT = dur!"seconds"(30);
alias SOCK_TIMEOUT_INFINITY = TIMEOUT_INFINITY;

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
    this(AsyncSocket sock, const(void[]) buf, Duration read_timeout = DEFAULT_SOCK_DATA_TIMEOUT, SocketFlags flags = SocketFlags.NONE) {
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

/**
 * Asyncronous variant of $(STDREF Socket, std,socket). Use it like the standard libary variant.
 */
class AsyncSocket {
    private socket_t sock;
    private AddressFamily address_family;

    /// Only to be used in `SocketAcceptFuture`.
    private this() {}

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
        auto f = new SocketRecvFuture(this, buf, read_timeout, flags);
        f.strict = true;
        return f;
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