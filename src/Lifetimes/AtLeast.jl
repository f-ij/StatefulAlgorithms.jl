#=
`AtLeast`: repeats until its condition holds, but at least `atleast` times. The condition reads the variables `Vars`
from the context.
=#

struct AtLeast{Vars, F} <: IndefiniteLifetime
    atleast::Int
    cond::F
end

AtLeast(cond::Function, atleast::Int, Vars...) = AtLeast{Vars, typeof(cond)}(atleast, cond)

@inline lifetime_breakcondition(lt::AL, context::C, done::D) where {Vars, AL<:AtLeast{Vars}, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, Vars...))
