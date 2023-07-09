module ninox.async.main;

/// Global to store the exit code for the asyncronous main
int g_async_exitcode = 0;

/// Global to store the commandline arguments for the asyncronous main
string[] g_async_args;

/**
 * Template to declare an asyncronous main.
 *
 * Example:
 * ---
 * import ninox.async;
 * mixin AsyncMain!"my_main";
 * int my_main(string[] args) {
 *     import core.time : seconds;
 *     timeout(seconds(5)).await();
 *     return 0;
 * }
 * ---
 * 
 * Params:
 *  func = the function to use as asyncronous main
 */
template AsyncMain(string func = "async_main") {
    mixin AsyncLoop!(func);

    int main(string[] args) {
        return mainAsyncLoop(args);
    }
}

template AsyncLoop(string func) {
    import std.meta : AliasSeq;
    import std.traits : isFunction, ReturnType, Parameters;

    alias __fun = mixin(func);
    static assert (isFunction!__fun, "`" ~ __traits(identifier, __fun) ~ "` needs to be a function");
    static assert (
        is(ReturnType!__fun == int),
        "`" ~ __traits(identifier, __fun) ~ "` is " ~ ReturnType!__fun.toString ~ " but should be `int` instead"
    );
    static if (is(Parameters!__fun == AliasSeq!(string[]))) {
        void asyncMainWrapper() { g_async_exitcode = __fun(g_async_args); }
    }
    else static if (is(Parameters!__fun == AliasSeq!())) {
        void asyncMainWrapper() { g_async_exitcode = __fun(); }
    }
    else {
        static assert(0, "`" ~ __traits(identifier, __fun) ~ "` needs to be callable with either no arguments or only with `string[]`");
    }

    int mainAsyncLoop(string[] args) {
        g_async_args = args;
        gscheduler.schedule(&asyncMainWrapper);
        gscheduler.loop();
        return g_async_exitcode;
    }
}
