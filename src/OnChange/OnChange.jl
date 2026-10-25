#=
OnChange: a stored value that runs a callback when a write changes it. The value carries its callback, so whoever
puts an `OnChange` into the context (an `init` return, an `Override`) decides what runs; the writes fire it, not the
definition. How it extends reading and writing stored values is in HookExtensions.jl next to this file.
=#

export OnChange

"""
    OnChange(value, callback, condition = !==)

A stored value that calls `callback(old, new)` when a write merges a value `new` for which `condition(old, new)` holds,
checked at each merge; by default when it is not `old` (`old !== new`). The callback runs after the merge. Algorithms
read it as `value`; a write keeps the wrapper and its type (`new` is converted to `value`'s type), so the context's type
does not change.

For a value written into in place (an array changed and returned as the same object), `old === new`: the default
condition does not hold.
"""
struct OnChange{T, F, C}
    value::T
    callback::F
    condition::C
end
OnChange(value::T, callback::F) where {T, F} = OnChange(value, callback, !==)

"""Run `callback(old, new)` when `condition(old, new)` holds: what an `OnChange` write runs after its merge."""
@inline function run_on_change(condition::C, callback::F, old::T, new::T) where {C, F, T}
    condition(old, new) && callback(old, new)
    return nothing
end

include("HookExtensions.jl")
