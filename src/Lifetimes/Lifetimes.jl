#=
Lifetimes: how long a process runs, and how often a routine repeats a child. Their logical stop check
(`lifetime_breakcondition`) is in Hooks.jl, and the methods of the lifetimes with their own condition in
HookExtensions.jl.
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


"""
Struct to define the lifetime of a process
Is a struct so that dispatch can be used to choose the appropriate loop during compile time

A lifetime with a condition reads the variables `vars` (`Var`s) from the context. They are a field, not a type
parameter: a `Var` of a `Unique` handle may hold its id as data (`Var`), which must stay out of types; the `Var`s' types
still decide the reads while compiling.
"""
struct Indefinite <: IndefiniteLifetime end
struct Repeat <: RepeatLifetime
    repeats::Int
end

"""
A single repeat: `Repeat(1)` whose type says the count. A routine stores a `Repeat(1)` child as `RepeatOnce()`
(`store_single_repeats_as_repeat_once`), so its step is compiled without a loop; any other count is a value, so a new
count does not compile the routine again.
"""
struct RepeatOnce <: RepeatLifetime end
repeats(::RepeatOnce) = 1


struct Until{V<:Tuple, F} <: IndefiniteLifetime
    cond::F
    vars::V
    Until(cond::Function, vars...) = new{typeof(vars), typeof(cond)}(cond, vars)
end


struct AtLeast{V<:Tuple, F} <: IndefiniteLifetime
    atleast::Int
    cond::F
    vars::V
    AtLeast(cond::Function, atleast::Int, vars...) = new{typeof(vars), typeof(cond)}(atleast, cond, vars)
end


struct RepeatOrUntil{V<:Tuple, F} <: RepeatLifetime
    repeats::Int
    cond::F
    vars::V
    RepeatOrUntil(cond::Function, repeats::Int, vars...) = new{typeof(vars), typeof(cond)}(repeats, cond, vars)
end
repeats(rou::RepeatOrUntil) = rou.repeats


struct AtLeastAtMost{V<:Tuple, F} <: RepeatLifetime
    atleast::Int
    repeats::Int
    cond::F
    vars::V
    AtLeastAtMost(cond::Function, atleast::Int, atmost::Int, vars...) = new{typeof(vars), typeof(cond)}(atleast, atmost, cond, vars)
end
repeats(aam::AtLeastAtMost) = aam.repeats
