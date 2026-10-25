#=
OnChange: a stored value that runs a callback when a write changes it. The value carries its callback, so whoever
puts an `OnChange` into the context (an `init` return, an `Override`) decides what runs; the writes fire it, not the
definition. How it extends reading and writing stored values is in HookExtensions.jl next to this file.
=#

export OnChange

"""
    OnChange(value, callback)

A stored value that calls `callback(old, new)` when a write merges a value that is not `old` (`old !== new`), checked
at each merge. Algorithms read it as `value`; a write keeps the wrapper and its type (`new` is converted to `value`'s
type), so the context's type does not change.

For a value written into in place (an array changed and returned as the same object), `old === new`: it does not fire.
"""
struct OnChange{T, F}
    value::T
    callback::F
end

include("HookExtensions.jl")
