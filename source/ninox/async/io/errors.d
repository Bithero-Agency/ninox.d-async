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
 * This module provides exception types used for IO actions.
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023-2025 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.io.errors;

/// Base Exception for all Socket things
class SocketException : Exception {
    enum Kind { error, hup, timeout }

    @property Kind kind() const {
        return this._kind;
    }

protected:
    Kind _kind;

    @nogc @safe pure nothrow string getMsg() {
        final switch (this._kind) {
            case Kind.error: { return "Error while trying do IO or while waiting"; }
            case Kind.hup: { return "IO failed because peer hung up"; }
            case Kind.timeout: { return "IO timeout reached without any data recieved"; }
        }
    }

    @nogc @safe pure nothrow this(Kind kind, string file = __FILE__, size_t line = __LINE__) {
        this._kind = kind;
        super(this.getMsg(), file, line, null);
    }
}

/// Exception for SocketRecvFuture
class SocketRecvException : SocketException {
    @nogc @safe pure nothrow this(Kind kind, string file = __FILE__, size_t line = __LINE__) {
        super(kind, file, line);
    }
}

/// Exception for SocketActivityFuture
class SocketActivityException : SocketException {
    @nogc @safe pure nothrow this(Kind kind, string file = __FILE__, size_t line = __LINE__) {
        super(kind, file, line);
    }
}

/// Exception for SocketSendFuture
class SocketSendException : SocketException {
    @nogc @safe pure nothrow this(Kind kind, string file = __FILE__, size_t line = __LINE__) {
        super(kind, file, line);
    }
}
