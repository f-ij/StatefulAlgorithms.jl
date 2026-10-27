export Var

"""
    Var(subcontext_ref, :name; transform = nothing)
    Var(:name)

Selects the variable `name` of a subcontext. `subcontext_ref` refers to it: an algorithm or
state as it was put into the plan (its type, or the instance), or a context key (`:Sensor_1`,
`:_captured_returns`, `:_declared_locals`). With
`transform`, reading it gives `transform(value)`. Read with `context[var]`, used by lifetimes
(`Until(cond, Var(counter, :count))`), and as the source of a wire in `WithWiring` (`From`).

`subcontext_ref` is stored as its matcher (`scref_matcher`) in the `matcher` field: a context key as a `KeyMatcher`,
anything else (a type, an instance, a `Unique` handle) as the matcher it is found by. The field's type `M` decides
the read while compiling: a key reads that subcontext, any other matcher the registry entry it matches
(`resolve_scref`); a type reads the first registered algorithm of that type. Only a matcher that carries data (a
`Unique` handle's `UniquePlanId`) takes bytes. The transform must be a plain function or a closure without captured
values, as for routes.
"""
struct Var{M, name, transform}
    matcher::M
end

# Typed: `c[Var(:key, :x)]` in a function is inferred and does not allocate.
Var(subcontext_ref, name::Symbol; transform = nothing) = _typed_var(scref_matcher(subcontext_ref), name, transform)
Var(subcontext_ref::IdentifiableAlgo{F, Id, VA, AN, K, Nothing}, name::Symbol; transform = nothing) where {F, Id, VA, AN, K} =
    _typed_var(scref_matcher(subcontext_ref), name, transform)
# A handle whose matcher carries data (a `Unique` handle) has a new type for every uuid: built untyped from its
# `matcher` field (which is what it is found by), so a new handle compiles nothing. The result is not inferred.
Base.@nospecializeinfer function Var(@nospecialize(subcontext_ref::IdentifiableAlgo), name::Symbol; transform = nothing)
    matcher = getfield(subcontext_ref, :matcher)
    return new_instance(Core.apply_type(Var, typeof(matcher), name, transform), matcher)
end
@inline _typed_var(matcher::M, name::Symbol, transform::T) where {M, T} = Var{M, name, transform}(matcher)
Var(name::Symbol) = Var(:_captured_returns, name)

"""
Return the subcontext a `Var` refers to: the one its `KeyMatcher` names, or the registry entry its
matcher matches (resolved as a route endpoint, so the key is found at compile time).
"""
@inline _var_subcontext(c::ProcessContext, ::Type{KeyMatcher{key}}) where {key} = c[key]
@inline function _var_subcontext(c::ProcessContext, ::Type{M}) where {M<:AbstractMatcher}
    reg = getregistry(c)
    isnothing(reg) && error("Cannot look up a `Var`'s subcontext without a registry in this context.")
    return getproperty(c, resolve_scref(reg, M, nothing, "Var subcontext"))
end

@inline _var_transform(::Var{M, N, nothing}, value) where {M, N} = value
@inline _var_transform(::Var{M, N, transform}, value) where {M, N, transform} = transform(value)

@inline function Base.getindex(c::ProcessContext, var::Var{M, name}) where {M, name}
    # A field redirected by `Redirect` reads the value of the field it points to, not its `RedirectedVar` marker.
    @inline _var_transform(var, (@inline _follow_reads(c, getproperty(_var_subcontext(c, M), name))))
end

"""The value stored at the state location `subcontext.field` of `c`, as stored: what a `ReadFrom` goes on with."""
@inline stored_value_at(c::ProcessContext, ::VarLocation{:state, subcontext, field}) where {subcontext, field} =
    @inline getproperty((@inline getproperty(c, subcontext)), field)

@inline function Base.getindex(c::ProcessContext, vars::Var...)
    ntuple(Val(length(vars))) do i
        @inline getindex(c, vars[i])
    end
end

@inline function Base.getindex(c::SubContext, vars::Var...)
    ntuple(Val(length(vars))) do i
        getindex(c, vars[i])
    end
end

"""
Read a DSL runtime variable selector from `ProcessContext._captured_returns`.
"""
@inline function Base.getindex(c::ProcessContext, var::Var{KeyMatcher{:_captured_returns}, name}) where {name}
    _var_transform(var, get_captured_returns(c)[name])
end
