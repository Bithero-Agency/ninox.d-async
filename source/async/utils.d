module async.utils;

class OptionIsNoneException : Exception {
    this (string s, string op) {
        super("Option " ~ s ~ " is none; operation " ~ op ~ " not permitted");
    }
}

struct Option(T) {
    private T value;
    private bool _isSome = false;

    this(T value, bool isSome) @disable;

    private this(T value) {
        this.value = value;
        this._isSome = true;
    }

    T take() {
        if (!_isSome) {
            throw new OptionIsNoneException(.stringof, ".take()");
        }
        return value;
    }

    bool isNone() {
        return !_isSome;
    }

    bool isSome() {
        return _isSome;
    }

    static Option none() {
        return Option();
    }

    static Option some(T value) {
        return Option(value);
    }
}
