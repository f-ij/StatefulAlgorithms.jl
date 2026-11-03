#=
`Until`: repeats until its condition holds. The condition reads the variables `Vars` from the context.
=#

struct Until{Vars, F} <: IndefiniteLifetime
    cond::F
end

Until(cond::Function, Vars...) = Until{Vars, typeof(cond)}(cond)

@inline lifetime_breakcondition(lt::U, context::C, done::D) where {Vars, U<:Until{Vars}, C, D<:Integer} =
    lt.cond(getindex(context, Vars...))
