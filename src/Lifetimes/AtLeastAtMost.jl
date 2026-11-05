#=
`AtLeastAtMost`: between `atleast` and `repeats` repeats, stopping when its condition holds. The condition reads the
variables `vars` from the context. A `Var` of a `Unique` handle may hold its id as data, which must stay out of types, so the `Var`s are a field, not
a type parameter; their types still decide the reads while compiling.
=#

struct AtLeastAtMost{V<:Tuple, F} <: RepeatLifetime
    atleast::Int
    repeats::Int
    cond::F
    vars::V
    AtLeastAtMost(cond::Function, atleast::Int, atmost::Int, vars...) = new{typeof(vars), typeof(cond)}(atleast, atmost, cond, vars)
end
repeats(aam::AtLeastAtMost) = aam.repeats

@inline lifetime_breakcondition(lt::AAM, context::C, done::D) where {AAM<:AtLeastAtMost, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, lt.vars...))
