#=
What a step returns. A step has a return value, as a Julia function has, and separately the values it writes back
(`StateUpdates`): an algorithm's state, or the variable of the block that was passed to it. `@StepAlgorithm` builds a
`StepReturn` from `return` and `@update`; a hand-written `step!` (deprecated: define algorithms with `@StepAlgorithm`)
may return one too.

A hand-written `step!` that returns a plain named tuple keeps the older meaning: every name is written back where it
lives (its state, or the wire it was read through), and the named tuple is also its return value.
=#
export StepReturn, StateUpdates, updated_names

"""
    StateUpdates(values::NamedTuple)
    StateUpdates(; names...)

The values a step writes back, by name: each name is written where the step read it from (its own state, or the
variable of the block wired to it).
"""
struct StateUpdates{NT<:NamedTuple}
    values::NT
end
StateUpdates(; values...) = StateUpdates(NamedTuple(values))

"""
    StepReturn(value, updates::StateUpdates)

What one step returns: its return `value` (what `y = Algo()` captures at the call site) and the `updates` it writes
back (see [`StateUpdates`](@ref)).
"""
struct StepReturn{V, U<:StateUpdates}
    value::V
    updates::U
end
StepReturn(value) = StepReturn(value, StateUpdates((;)))

"""
    updated_names(algo or its type)

The names of the arguments an algorithm's step writes back, as a tuple of symbols: `updated_names(AddOne!) == (:val,)`.

When a block is built, the DSL reads it for every algorithm statement: a value of the block passed to one of these
arguments changes, so it warns unless the value is state or declared `@mutable`, and an `@input`, an outside value or
a `@transform` passed there is an error.

`@StepAlgorithm` defines it from the body's `@update`s. A hand-written `step!` (deprecated) that returns
`StepReturn(value, StateUpdates(; x))` defines it with the same names, so these checks apply to it too:

```julia
StatefulAlgorithms.updated_names(::Type{MyAlgo}) = (:x,)
```

Without a method it is `()`: the step still writes back what it returns, but building a block checks nothing for it
(also for a hand-written `step!` that returns a plain named tuple, which writes every name back).
"""
updated_names(::Type) = ()
updated_names(algo) = updated_names(typeof(algo))

"""The return value of what a step returned: a `StepReturn`'s value, else the returned value itself."""
@inline step_value(result::StepReturn) = getfield(result, :value)
@inline step_value(result) = result

"""
What a step writes back, as a named tuple: a `StepReturn`'s updates; a plain named tuple (the older meaning: every
name is written back); nothing for anything else.
"""
@inline step_updates(result::StepReturn) = getfield(getfield(result, :updates), :values)
@inline step_updates(result::NamedTuple) = result
@inline step_updates(::Any) = (;)

"""The name an algorithm's return value is kept under for one step, for the statements that capture it."""
const RETURN_NAME = :_return
