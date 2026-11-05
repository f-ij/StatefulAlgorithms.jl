#=
`Until`: repeats until its condition holds. The condition reads the variables `vars` from the context.
A `Var` of a `Unique` handle may hold its id as data, which must stay out of types, so the `Var`s are a field, not
a type parameter; their types still decide the reads while compiling.
=#

struct Until{V<:Tuple, F} <: IndefiniteLifetime
    cond::F
    vars::V
end
# Built untyped: a `Var` of a `Unique` handle puts its uuid in `vars`' type, so a typed constructor would compile once for
# every new handle. Only built while constructing a plan or process.
Base.@nospecializeinfer Until(@nospecialize(cond::Function), @nospecialize(vars...)) =
    new_instance(Core.apply_type(Until, typeof(vars), typeof(cond)), cond, vars)

@inline lifetime_breakcondition(lt::U, context::C, done::D) where {U<:Until, C, D<:Integer} =
    (@inline lt.cond((@inline getindex(context, lt.vars...))))

# The same lifetime with its `Var`s given their context keys (`resolve_var_keys`, Lifetimes/Hooks.jl).
@inline function resolve_var_keys(lt::U, context::C) where {V, F, U<:Until{V, F}, C}
    vars = @inline _resolve_var_keys(lt.vars, context)
    return Until{typeof(vars), F}(lt.cond, vars)
end
