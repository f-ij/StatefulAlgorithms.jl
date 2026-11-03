#=
`RepeatOrUntil`: at most `repeats` repeats, fewer when its condition holds first. The condition reads the variables
`Vars` from the context.
=#

struct RepeatOrUntil{Vars, F} <: RepeatLifetime
    repeats::Int
    cond::F
end
repeats(rou::RepeatOrUntil) = rou.repeats

RepeatOrUntil(cond::Function, repeats::Int, Vars...) = RepeatOrUntil{Vars, typeof(cond)}(repeats, cond)

@inline lifetime_breakcondition(lt::ROU, context::C, done::D) where {Vars, ROU<:RepeatOrUntil{Vars}, C, D<:Integer} =
    lt.cond(getindex(context, Vars...))
