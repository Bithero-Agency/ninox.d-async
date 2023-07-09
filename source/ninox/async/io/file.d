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
 * This module provides asyncronous access to file IO
 *
 *  - $(LREF readAsync) and $(LREF writeAsync) provide an api like
 *    $(STDREF read, std,file) and $(STDREF write, std,file) from the standard library
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.io.file;

import std.traits : isConvertibleToString, isNarrowString, isSomeString;
import std.range : isSomeFiniteCharInputRange;
import std.internal.cstring : tempCString;
import std.stdio : writeln;

import ninox.async.futures : Future, VoidFuture;
import ninox.async : gscheduler;

version (Windows) {
    private alias FSChar = WCHAR;
}
else version (Posix) {
    private alias FSChar = char;
    import core.sys.posix.fcntl, core.sys.posix.sys.ioctl, core.sys.posix.unistd;
}
else { static assert(false, "Module " ~ .stringof ~ " not implemented for this OS."); }

static int MAX_FILE_READBLOCK = 4096;
static int MAX_FILE_WRITEBLOCK = 4096;

/** 
 * Future for a $(STDREF read, std,file) like api; reads `upTo` bytes from a file, or everything if `upTo` is `size_t.max`.
 * Use $(LREF readAsync) to create this future.
 *
 * Note: The read process is chunked and only reads `MAX_FILE_READBLOCK` bytes at a time.
 *
 * See_Also: $(LREF readAsync) to create a instance of this future
 */
class FileReadFuture : Future!(void[]) {
    private immutable int fd;
    private size_t upTo;
    private bool hasUpTo = false;
    private void[] value;

    version (Posix) this(scope const(FSChar)* namez, size_t upTo = size_t.max) {
        this.fd = open(namez, O_RDONLY);
        this.upTo = upTo;
        this.hasUpTo = upTo != size_t.max;
    }

    protected override void[] getValue() {
        return this.value;
    }

    version (Posix) protected override bool isDone() {
        // read all available bytes...
        int count = 0;
        ioctl(this.fd, FIONREAD, &count);
        if (count > 0) {
            import std.algorithm : min;
            size_t readsize = count;
            if (!this.hasUpTo) {
                readsize = min(count, MAX_FILE_READBLOCK);
            } else {
                readsize = min(count, this.upTo, MAX_FILE_READBLOCK);
            }

            void[] block = new void[readsize];
            size_t r = read(this.fd, block.ptr, block.length);
            if (this.hasUpTo) {
                this.upTo -= r;
            }

            debug (ninoxasync_fileio) {
                import std.stdio : writeln;
                writeln("[ninox.async.io.file.FileReadFuture] read ", r, " bytes");
            }

            this.value ~= block;

            if (readsize < count) {
                gscheduler.addIoWaiter(this.fd);
                return false;
            }
        }

        close(this.fd);
        return true;
    }

}

/** 
 * Async version of $(STDREF read, std,file).
 * Reads `upTo` bytes from a file, or everything if `upTo` is `size_t.max`.
 * The read process is chunked and only reads `MAX_FILE_READBLOCK` bytes at a time.
 * See $(LREF FileReadFuture) for details.
 *
 * Example:
 * ---
 * import std.utf : byChar;
 * scope(exit) {
 *     assert(exists(deleteme));
 *     remove(deleteme);
 * }
 * 
 * writeAsync(deleteme, "1234").await();
 * writeln(readAsync(deleteme, 2).await()); // "12"
 * writeln(readAsync(deleteme.byChar).await()); // "1234"
 * writeln((cast(const(ubyte)[])readAsync(deleteme).await()).length); // 4
 * ---
 *
 * Params:
 *     name = string or range of characters representing the filename
 *     upTo = if present, the maximum number of bytes to read
 *
 * Returns: A future resolving to an untyped array of bytes read.
 *
 * See_Also:
 *     $(LREF FileReadFuture) for the future returned,
 *     $(STDREF read, std,file) for the standard-library equivalent.
 */
FileReadFuture readAsync(R)(R name, size_t upTo = size_t.max)
if (isSomeFiniteCharInputRange!R && !isConvertibleToString!R)
{
    static if (isNarrowString!R && is(immutable ElementEncodingType!R == immutable char))
        return readAsyncImpl(name, name.tempCString!FSChar(), upTo);
    else
        return readAsyncImpl(null, name.tempCString!FSChar(), upTo);
}

/// ditto
FileReadFuture readAsync(R)(auto ref R name, size_t upTo = size_t.max)
if (isConvertibleToString!R)
{
    return readAsync!(StringTypeOf!R)(name, upTo);
}

private FileReadFuture readAsyncImpl(scope const(char)[] name, scope const(FSChar)* namez, size_t upTo) @trusted
{
    return new FileReadFuture(namez, upTo);
}

/**
 * Future for a $(REF write, std,file) like api; writes `buffer` to a file.
 * Use $(LREF writeAsync) to create this future.
 *
 * Note: The write process is chunked and only writes `MAX_FILE_WRITEBLOCK` bytes at a time.
 *
 * See_Also: $(LREF writeAsync) to create a instance of this future
 */
class FileWriteFuture : VoidFuture {
    private immutable int fd;
    private const void[] buffer;

    version (Posix) this(scope const(FSChar)* namez, const void[] buffer) {
        this.fd = open(namez, O_WRONLY);
        this.buffer = buffer;
    }

    version (Posix) override bool isDone() {
        import std.algorithm : min;
        auto writesize = min(this.buffer.length, MAX_FILE_WRITEBLOCK);

        auto block = this.buffer[1 .. writesize];
        auto r = write(this.fd, block.ptr, block.length);

        debug (ninoxasync_fileio) {
            import std.stdio : writeln;
            writeln("[ninox.async.io.file.FileWriteFuture] written ", r, " bytes");
        }

        return this.buffer.length <= 0;
    }

}

/** 
 * Async version of $(STDREF write, std,file).
 * The write process is chunked and only writes `MAX_FILE_WRITEBLOCK` bytes at a time.
 * See $(LREF FileWriteFuture) for details.
 *
 * Example:
 * ---
 * scope(exit) {
 *     assert(exists(deleteme));
 *     remove(deleteme);
 * }
 * 
 * int[] a = [ 0, 1, 1, 2, 3, 5, 8 ];
 * writeAsync(deleteme, a).await(); // deleteme is the name of a temporary file
 * const bytes = readAsync(deleteme).await();
 * const fileInts = () @trusted { return cast(int[]) bytes; }();
 * writeln(fileInts); // a
 * ---
 *
 * Params:
 *     name = string or range of characters representing the file _name
 *     buffer = data to be written to file
 *
 * Returns: A future resolving once the complete buffer was written.
 *
 * See_Also:
 *     $(LREF FileWriteFuture) for the future returned,
 *     $(STDREF write, std,file) for the standard-library equivalent.
 */
FileWriteFuture writeAsync(R)(R name, const void[] buffer)
if ((isSomeFiniteCharInputRange!R || isSomeString!R) && !isConvertibleToString!R)
{
    static if (isNarrowString!R && is(immutable ElementEncodingType!R == immutable char))
        return writeAsyncImpl(name, name.tempCString!FSChar(), buffer, false);
    else
        return writeAsyncImpl(null, name.tempCString!FSChar(), buffer, false);
}

/// ditto
FileWriteFuture writeAsync(R)(auto ref name, const void[] buffer)
if (isConvertibleToString!R)
{
    return writeAsync!(StringTypeOf!R)(name, buffer);
}

private FileWriteFuture writeAsyncImpl(scope const(char)[] name, scope const(FSChar)* namez, const void[] buffer) {
    return new FileWriteFuture(namez, buffer);
}

