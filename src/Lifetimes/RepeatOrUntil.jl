#=
`RepeatOrUntil`: at most `repeats` repeats, fewer when its condition holds first. The condition reads the variables
`vars` from the context. A `Var` of a `Unique` handle may hold its id as data, which must stay out of types, so the `Var`s are a field, not
a type parameter; their types still decide the reads while compiling.
=#

struct RepeatOrUntil{V<:Tuple, F} <: RepeatLifetime
    repeats::Int
    cond::F
    vars::V
end
# Built untyped: a `Var` of a `Unique` handle puts its uuid in `vars`' type, so a typed constructor would compile once for
# every new handle. Only built while constructing a plan or process.
Base.@nospecializeinfer RepeatOrUntil(@nospecialize(cond::Function), repeats::Int, @nospecialize(vars...)) =
    new_instance(Core.apply_type(RepeatOrUntil, typeof(vars), typeof(cond)), repeats, cond, vars)
repeats(rou::RepeatOrUntil) = rou.repeats

@inline lifetime_breakcondition(lt::ROU, context::C, done::D) where {ROU<:RepeatOrUntil, C, D<:Integer} =
    lt.cond(getindex(context, lt.vars...))
