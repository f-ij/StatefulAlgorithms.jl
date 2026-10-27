#=
How lifetimes with their own stop condition extend the logical stop check `lifetime_breakcondition` (Hooks.jl next to
this file): `Until` and `RepeatOrUntil` stop when their condition holds; `AtLeast` and `AtLeastAtMost` only after at
least `atleast` repeats. `Repeat` and `Indefinite` have no condition of their own and use the default.

The condition reads the variables `vars` (a field) from the context; `resolve_var_keys` gives them their context keys
before the loop runs. A pause or close is not checked here: that is
`process_breakcondition` (Sessions/Hooks.jl).
=#

@inline lifetime_breakcondition(lt::U, context::C, done::D) where {U<:Until, C, D<:Integer} =
    lt.cond(getindex(context, lt.vars...))

@inline lifetime_breakcondition(lt::ROU, context::C, done::D) where {ROU<:RepeatOrUntil, C, D<:Integer} =
    lt.cond(getindex(context, lt.vars...))

@inline lifetime_breakcondition(lt::AL, context::C, done::D) where {AL<:AtLeast, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, lt.vars...))

@inline lifetime_breakcondition(lt::AAM, context::C, done::D) where {AAM<:AtLeastAtMost, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, lt.vars...))

# The same lifetime with its `Var`s given their context keys (`resolve_var_keys`, Hooks.jl).
@inline _resolve_var_keys(vars::V, registry::R) where {V<:Tuple, R} = map(var -> (@inline resolve_var_key(var, registry)), vars)

@inline function resolve_var_keys(lt::U, registry::R) where {V, F, U<:Until{V, F}, R}
    vars = @inline _resolve_var_keys(lt.vars, registry)
    return Until{typeof(vars), F}(lt.cond, vars)
end
@inline function resolve_var_keys(lt::AL, registry::R) where {V, F, AL<:AtLeast{V, F}, R}
    vars = @inline _resolve_var_keys(lt.vars, registry)
    return AtLeast{typeof(vars), F}(lt.atleast, lt.cond, vars)
end
@inline function resolve_var_keys(lt::ROU, registry::R) where {V, F, ROU<:RepeatOrUntil{V, F}, R}
    vars = @inline _resolve_var_keys(lt.vars, registry)
    return RepeatOrUntil{typeof(vars), F}(lt.repeats, lt.cond, vars)
end
@inline function resolve_var_keys(lt::AAM, registry::R) where {V, F, AAM<:AtLeastAtMost{V, F}, R}
    vars = @inline _resolve_var_keys(lt.vars, registry)
    return AtLeastAtMost{typeof(vars), F}(lt.atleast, lt.repeats, lt.cond, vars)
end
