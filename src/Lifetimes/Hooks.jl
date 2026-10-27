#=
Extendable API of lifetimes: the logical stop check, whether a lifetime's own condition ends the repeats, and the
`Var`s it reads, given their context keys before the loop runs.

Each function here has the default every lifetime gets. Extended in HookExtensions.jl next to this file: `Until`,
`AtLeast`, `RepeatOrUntil`, `AtLeastAtMost`.

The interactive stop check, a pause or close of the process, is `process_breakcondition` (Sessions/Hooks.jl).
=#

"""
    lifetime_breakcondition(lifetime, context, done) -> Bool

Whether `lifetime`'s own stop condition holds after `done` repeats: no further repeat runs. Checked before every
repeat, as a `while` loop's condition, at both levels in the same way: before every step of the process loop with the
process's lifetime (`Loops.jl`, `done` the steps done), and before every repeat of a routine child with the child's
lifetime (`LoopAlgorithms/Step.jl`, `done` the repeats of the child done in this step). If it already holds before the
first repeat, nothing runs. `context` holds the persistent and the runtime values (declared locals too).

`false` by default (`Repeat`, `Indefinite`: they end by their repeat count, or never). How many repeats a `Repeat`
lifetime runs is the loop's bound, not this check.
"""
@inline lifetime_breakcondition(lifetime::LT, context::C, done::D) where {LT<:Lifetime, C, D<:Integer} = false

"""
    resolve_var_keys(lifetime, context) -> lifetime

`lifetime` with the `Var`s its condition reads given their context keys (`resolve_var_key`, from `context`'s
registry, while compiling). Done before the loop: when an `InlineProcess` is built, in `run(ip; lifetime)`, and at the
start of the loop for the other runs (which keeps a `Var` that has its key as it is, without reading the registry).
So the stop check before every step reads its variables by key and never loads the registry (a load and a null check
per step, which also made LLVM store the step counter to the session every step). `lifetime` itself by default (no
`Var`s).
"""
@inline resolve_var_keys(lifetime::LT, context::C) where {LT<:Lifetime, C} = lifetime
