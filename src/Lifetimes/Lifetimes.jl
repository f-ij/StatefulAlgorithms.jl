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


struct Until{Vars, F} <: IndefiniteLifetime
    cond::F
end

Until(cond::Function, Vars...) = Until{Vars, typeof(cond)}(cond)


struct AtLeast{Vars, F} <: IndefiniteLifetime
    atleast::Int
    cond::F
end

AtLeast(cond::Function, atleast::Int, Vars...) = AtLeast{Vars, typeof(cond)}(atleast, cond)


struct RepeatOrUntil{Vars, F} <: RepeatLifetime
    repeats::Int
    cond::F
end
repeats(rou::RepeatOrUntil) = rou.repeats


RepeatOrUntil(cond::Function, repeats::Int, Vars...) = RepeatOrUntil{Vars, typeof(cond)}(repeats, cond)


struct AtLeastAtMost{Vars, F} <: RepeatLifetime
    atleast::Int
    repeats::Int
    cond::F
end
repeats(aam::AtLeastAtMost) = aam.repeats

AtLeastAtMost(cond::Function, atleast::Int, atmost::Int, Vars...) = AtLeastAtMost{Vars, typeof(cond)}(atleast, atmost, cond)
