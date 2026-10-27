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
@inline _resolve_var_keys(vars::V, context::C) where {V<:Tuple, C} = map(var -> (@inline resolve_var_key(var, context)), vars)

@inline function resolve_var_keys(lt::U, context::C) where {V, F, U<:Until{V, F}, C}
    vars = @inline _resolve_var_keys(lt.vars, context)
    return Until{typeof(vars), F}(lt.cond, vars)
end
@inline function resolve_var_keys(lt::AL, context::C) where {V, F, AL<:AtLeast{V, F}, C}
    vars = @inline _resolve_var_keys(lt.vars, context)
    return AtLeast{typeof(vars), F}(lt.atleast, lt.cond, vars)
end
@inline function resolve_var_keys(lt::ROU, context::C) where {V, F, ROU<:RepeatOrUntil{V, F}, C}
    vars = @inline _resolve_var_keys(lt.vars, context)
    return RepeatOrUntil{typeof(vars), F}(lt.repeats, lt.cond, vars)
end
@inline function resolve_var_keys(lt::AAM, context::C) where {V, F, AAM<:AtLeastAtMost{V, F}, C}
    vars = @inline _resolve_var_keys(lt.vars, context)
    return AtLeastAtMost{typeof(vars), F}(lt.atleast, lt.repeats, lt.cond, vars)
end
