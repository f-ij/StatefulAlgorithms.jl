#=
`Until`: repeats until its condition holds. The condition reads the variables `vars` from the context.
A `Var` of a `Unique` handle may hold its id as data, which must stay out of types, so the `Var`s are a field, not
a type parameter; their types still decide the reads while compiling.
=#

struct Until{V<:Tuple, F} <: IndefiniteLifetime
    cond::F
    vars::V
    Until(cond::Function, vars...) = new{typeof(vars), typeof(cond)}(cond, vars)
end

@inline lifetime_breakcondition(lt::U, context::C, done::D) where {U<:Until, C, D<:Integer} =
    lt.cond(getindex(context, lt.vars...))
