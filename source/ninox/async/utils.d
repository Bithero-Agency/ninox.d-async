module ninox.async.utils;

template MakeClosure() {
    import std.traits : ReturnType, isFunction;
    C makeClosure(
        string func,
        C = ReturnType!(mixin(func)) delegate(),
        T...
    )(T args)
    if (isFunction!(mixin(func)))
    {
        alias __fun = mixin(func);
        return { return __fun(args); };
    }
}