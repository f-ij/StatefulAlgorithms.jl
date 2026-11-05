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
end
# Built untyped: a `Var` of a `Unique` handle puts its uuid in `vars`' type, so a typed constructor would compile once for
# every new handle. Only built while constructing a plan or process.
Base.@nospecializeinfer AtLeastAtMost(@nospecialize(cond::Function), atleast::Int, atmost::Int, @nospecialize(vars...)) =
    new_instance(Core.apply_type(AtLeastAtMost, typeof(vars), typeof(cond)), atleast, atmost, cond, vars)
repeats(aam::AtLeastAtMost) = aam.repeats

@inline lifetime_breakcondition(lt::AAM, context::C, done::D) where {AAM<:AtLeastAtMost, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, lt.vars...))

# The same lifetime with its `Var`s given their context keys (`resolve_var_keys`, Lifetimes/Hooks.jl).
@inline function resolve_var_keys(lt::AAM, context::C) where {V, F, AAM<:AtLeastAtMost{V, F}, C}
    vars = @inline _resolve_var_keys(lt.vars, context)
    return AtLeastAtMost{typeof(vars), F}(lt.atleast, lt.repeats, lt.cond, vars)
end
