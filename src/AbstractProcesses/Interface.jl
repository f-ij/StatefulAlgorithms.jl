#=
Interface of `AbstractProcess`: what every process provides (its loop counter, its stop check), with defaults that a
process type can overload.
=#

loopidx(p::AbstractProcess) = p.loopidx
setloopidx!(p::AbstractProcess, value) = (p.loopidx = value)
reset_loopidx!(p::AbstractProcess) = setloopidx!(p, oneunit(loopidx(p)))

loopint(p::AbstractProcess) = Int(loopidx(p))
getlidx(p::AbstractProcess) = loopint(p)

@inline inc!(p::AbstractProcess) = p.loopidx += oneunit(p.loopidx)
@inline tick!(p::AbstractProcess) = nothing

"""
    _process_breakcondition(lifetime, process, context) -> Bool

Whether the process stops: checked by the process loop after every step, and inside a routine after every repeat of a
child. By default (`Repeat`, `Indefinite`), when the process is paused or closed (`!shouldrun(process)`). A lifetime
with its own stop condition (`Until`, `AtLeast`, ...) adds a method next to its definition (`Lifetime.jl`) that also
checks that condition, read from `context`.

Repeats can run for a very long time, so a pause or close of a `Process` must be seen between any two of them, not once
per child. See `shouldrun(::Process)`. A routine child's own stop condition is `_routine_breakcondition`.
"""
@inline _process_breakcondition(lifetime::LT, process::P, context::C) where {LT<:Lifetime,P<:AbstractProcess,C} =
    @inline !shouldrun(process)

export loopidx, loopint, getlidx, inc!
