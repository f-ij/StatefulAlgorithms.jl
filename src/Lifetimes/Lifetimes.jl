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


# The lifetimes with a condition are built untyped: a `Var` of a `Unique` handle puts its uuid in `vars`' type, so a
# typed constructor would compile once for every new handle. They are only built while constructing a plan or process.
struct Until{V<:Tuple, F} <: IndefiniteLifetime
    cond::F
    vars::V
end
Base.@nospecializeinfer Until(@nospecialize(cond::Function), @nospecialize(vars...)) =
    new_instance(Core.apply_type(Until, typeof(vars), typeof(cond)), cond, vars)


struct AtLeast{V<:Tuple, F} <: IndefiniteLifetime
    atleast::Int
    cond::F
    vars::V
end
Base.@nospecializeinfer AtLeast(@nospecialize(cond::Function), atleast::Int, @nospecialize(vars...)) =
    new_instance(Core.apply_type(AtLeast, typeof(vars), typeof(cond)), atleast, cond, vars)


struct RepeatOrUntil{V<:Tuple, F} <: RepeatLifetime
    repeats::Int
    cond::F
    vars::V
end
Base.@nospecializeinfer RepeatOrUntil(@nospecialize(cond::Function), repeats::Int, @nospecialize(vars...)) =
    new_instance(Core.apply_type(RepeatOrUntil, typeof(vars), typeof(cond)), repeats, cond, vars)
repeats(rou::RepeatOrUntil) = rou.repeats


struct AtLeastAtMost{V<:Tuple, F} <: RepeatLifetime
    atleast::Int
    repeats::Int
    cond::F
    vars::V
end
Base.@nospecializeinfer AtLeastAtMost(@nospecialize(cond::Function), atleast::Int, atmost::Int, @nospecialize(vars...)) =
    new_instance(Core.apply_type(AtLeastAtMost, typeof(vars), typeof(cond)), atleast, atmost, cond, vars)
repeats(aam::AtLeastAtMost) = aam.repeats
