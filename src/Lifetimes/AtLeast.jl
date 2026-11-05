#=
`AtLeast`: repeats until its condition holds, but at least `atleast` times. The condition reads the variables `vars`
from the context. A `Var` of a `Unique` handle may hold its id as data, which must stay out of types, so the `Var`s are a field, not
a type parameter; their types still decide the reads while compiling.
=#

struct AtLeast{V<:Tuple, F} <: IndefiniteLifetime
    atleast::Int
    cond::F
    vars::V
end
# Built untyped: a `Var` of a `Unique` handle puts its uuid in `vars`' type, so a typed constructor would compile once for
# every new handle. Only built while constructing a plan or process.
Base.@nospecializeinfer AtLeast(@nospecialize(cond::Function), atleast::Int, @nospecialize(vars...)) =
    new_instance(Core.apply_type(AtLeast, typeof(vars), typeof(cond)), atleast, cond, vars)

@inline lifetime_breakcondition(lt::AL, context::C, done::D) where {AL<:AtLeast, C, D<:Integer} =
    done >= lt.atleast && (@inline lt.cond((@inline getindex(context, lt.vars...))))

# The same lifetime with its `Var`s given their context keys (`resolve_var_keys`, Lifetimes/Hooks.jl).
@inline function resolve_var_keys(lt::AL, context::C) where {V, F, AL<:AtLeast{V, F}, C}
    vars = @inline _resolve_var_keys(lt.vars, context)
    return AtLeast{typeof(vars), F}(lt.atleast, lt.cond, vars)
end
