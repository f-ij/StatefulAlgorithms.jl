#=
Extendable API of routines: the check, before each repeat of a child, whether the child is finished.

Each function here has the default every lifetime gets. Extended in Lifetimes/HookExtensions.jl: `Until`,
`RepeatOrUntil`, `AtLeast`, `AtLeastAtMost` (their own stop condition).
=#

"""
    routine_breakcondition(child_lifetime, process, context, done) -> Bool

Whether a routine child's own stop condition holds, with `done` repeats of the child done (in this step): the child is
finished. Checked before each repeat, as a `while` loop's condition (if it already holds, the child does not run).
`false` by default (`Repeat`, `Indefinite`); `Until`, `RepeatOrUntil`, `AtLeast` and `AtLeastAtMost` add a method in
Lifetimes/HookExtensions.jl. A pause or close of the process is `process_breakcondition` (AbstractProcesses/Hooks.jl).
"""
@inline routine_breakcondition(spec::LT, process::P, context::C, done::LI) where {LT<:Lifetime,P<:AbstractProcess,C,LI<:Integer} = false
