#=
`AtLeastAtMost`: between `atleast` and `repeats` repeats, stopping when its condition holds. The condition reads the
variables `Vars` from the context.
=#

struct AtLeastAtMost{Vars, F} <: RepeatLifetime
    atleast::Int
    repeats::Int
    cond::F
end
repeats(aam::AtLeastAtMost) = aam.repeats

AtLeastAtMost(cond::Function, atleast::Int, atmost::Int, Vars...) = AtLeastAtMost{Vars, typeof(cond)}(atleast, atmost, cond)

@inline lifetime_breakcondition(lt::AAM, context::C, done::D) where {Vars, AAM<:AtLeastAtMost{Vars}, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, Vars...))
