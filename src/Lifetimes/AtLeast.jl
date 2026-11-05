#=
`AtLeast`: repeats until its condition holds, but at least `atleast` times. The condition reads the variables `vars`
from the context. A `Var` of a `Unique` handle may hold its id as data, which must stay out of types, so the `Var`s are a field, not
a type parameter; their types still decide the reads while compiling.
=#

struct AtLeast{V<:Tuple, F} <: IndefiniteLifetime
    atleast::Int
    cond::F
    vars::V
    AtLeast(cond::Function, atleast::Int, vars...) = new{typeof(vars), typeof(cond)}(atleast, cond, vars)
end

@inline lifetime_breakcondition(lt::AL, context::C, done::D) where {AL<:AtLeast, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, lt.vars...))
