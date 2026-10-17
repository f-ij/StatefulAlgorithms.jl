#=
Extendable API of routines: the stop checks a routine runs between repeats of its children. A lifetime with its own
stop condition adds a method next to its definition (`Lifetime.jl`).
=#

"""
    _routine_breakcondition(child_lifetime, process, context, done) -> Bool

Whether a routine child's own stop condition holds, with `done` repeats of the child done (in this step): the child is
finished. Checked before each repeat, as a `while` loop's condition (if it already holds, the child does not run).
`false` by default (`Repeat`, `Indefinite`); `Until`, `RepeatOrUntil`, `AtLeast` and `AtLeastAtMost` add a method. A
pause or close of the process is `_process_breakcondition`.
"""
@inline _routine_breakcondition(spec::LT, process::P, context::C, done::LI) where {LT<:Lifetime,P<:AbstractProcess,C,LI<:Integer} = false

"""
    _process_breakcondition(lifetime, process, context) -> Bool

Whether the process stops (`breakcondition` of its lifetime: for `Repeat`, a pause or close, `!shouldrun(process)`), as
checked inside a routine: after every repeat of a child. Repeats can run for a very long time, so a pause or close of a
`Process` must be seen between any two of them, not once per child. See `shouldrun(::Process)`. The child's own stop
condition is `_routine_breakcondition`.
"""
@inline _process_breakcondition(lifetime::LT, process::P, context::C) where {LT<:Lifetime,P<:AbstractProcess,C} =
    @inline breakcondition(lifetime, process, context)
