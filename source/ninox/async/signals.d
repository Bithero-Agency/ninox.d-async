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
 * Routines for signal handling
 * 
 * License:   $(HTTP https://www.gnu.org/licenses/agpl-3.0.html, AGPL 3.0).
 * Copyright: Copyright (C) 2023 Mai-Lapyst
 * Authors:   $(HTTP codeark.it/Mai-Lapyst, Mai-Lapyst)
 */

module ninox.async.signals;

version (Posix) {
	import core.sys.posix.signal;
}
else {
	static assert(false, "Module " ~ .stringof ~ " dosnt support this OS.");
}

private extern(C) void handleBrokenPipe(int signal) nothrow {}

private extern(C) void handleShutdown(int signal) nothrow {
	import ninox.async;
	try {
		gscheduler.shutdown();
	} catch (Throwable th) {}
}

void setupSignals() {
	version (Posix) {
		sigset_t sigset;
		sigemptyset(&sigset);

		sigaction_t siginfo;
		siginfo.sa_handler = &handleBrokenPipe;
		siginfo.sa_mask = sigset;
		siginfo.sa_flags = SA_RESTART;
		sigaction(SIGPIPE, &siginfo, null);

		siginfo.sa_handler = &handleShutdown;
		sigaction(SIGINT, &siginfo, null);
		sigaction(SIGTERM, &siginfo, null);
	}
}
