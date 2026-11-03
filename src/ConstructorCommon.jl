"""
Throw `ErrorException(string(parts...))`, or `AssertionError` from `construction_assert_error`.

Construction code uses these instead of `error("... \$(value) ...")` and `@assert cond "... \$(value)"`: Julia compiles
the message (`string` and `show` of the value) even when the error never fires, and compiles it again for every new
value type, such as every `Unique` handle. Here the message is only built when the error is thrown.
"""
@noinline Base.@nospecializeinfer construction_error(@nospecialize(parts...)) = error(parts...)
@noinline Base.@nospecializeinfer construction_assert_error(@nospecialize(parts...)) = throw(AssertionError(string(parts...)))
