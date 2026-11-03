#=
Lifetimes: how long a process runs, and how often a routine repeats a child. This folder holds what every lifetime
shares: the abstract types and `repeats` (here) and the logical stop check `lifetime_breakcondition` with its default
(Hooks.jl). Each lifetime type has its own file (`Repeat.jl`, `Until.jl`, ...), which also holds that type's method of
the stop check when it has a condition of its own.
=#

export Repeat, RepeatOnce, Indefinite, Until, AtLeast, RepeatOrUntil, AtLeastAtMost
export repeats

abstract type Lifetime end

abstract type RepeatLifetime <: Lifetime end
abstract type IndefiniteLifetime <: Lifetime end

Base.:(/)(r::RepeatLifetime, n) = repeats(r) / n
repeats(r::RepeatLifetime) = r.repeats

repeats(::IndefiniteLifetime) = Inf
repeats(p::AbstractProcess) = repeats(lifetime(p))
