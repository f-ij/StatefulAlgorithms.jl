export Var

"""
    Var(subcontext_ref, :name; transform = nothing)
    Var(:name)

Selects the variable `name` of a subcontext. `subcontext_ref` refers to it: an algorithm or
state as it was put into the plan (its type, or the instance), or a context key (`:Sensor_1`,
`:_captured_returns`, `:_declared_locals`). With
`transform`, reading it gives `transform(value)`. Read with `context[var]`, used by lifetimes
(`Until(cond, Var(counter, :count))`), and as the source of a wire in `WithWiring` (`From`).

Everything is type data. `subcontext_ref` is stored as an SCRef is stored in a route
(`scref_match`): a context key as itself, anything else (a type, an instance) as its matcher type.
Reading the `Var` resolves the matcher to a key in the context's registry (`resolve_scref`); a type
reads the first registered algorithm of that type. The transform must be a plain function or a
closure without captured values, as for routes.
"""
struct Var{SubcontextRef, name, transform} end

Var(subcontext_ref, name::Symbol; transform = nothing) = Var{_var_match(subcontext_ref), name, transform}()

# A `Var` holds its SCRef only in its type, so a `Unique` handle that a constructor stripped (`UniquePlanId{nothing}`)
# is stored with its uuid again (`UniquePlanId{uuid}`): the plan numbers it by that (`number_unique_ids`).
function _var_match(ref)
    m = scref_match(ref)
    m === UniquePlanId{nothing} || return m
    return typeof(UniquePlanId(origin(match_by(ref))))
end
Var(name::Symbol) = Var{:_captured_returns, name, nothing}()

"""
Return the subcontext a `Var` refers to: the one named by its SCKey, or the registry entry its
matcher matches (resolved as a route endpoint, so the key is found at compile time).
"""
@inline _var_subcontext(c::ProcessContext, key::Symbol) = c[key]
@inline function _var_subcontext(c::ProcessContext, ::Type{M}) where {M<:AbstractMatcher}
    reg = getregistry(c)
    isnothing(reg) && error("Cannot look up a `Var`'s subcontext without a registry in this context.")
    return getproperty(c, resolve_scref(reg, M, nothing, "Var subcontext"))
end

@inline _var_transform(::Var{E, N, nothing}, value) where {E, N} = value
@inline _var_transform(::Var{E, N, transform}, value) where {E, N, transform} = transform(value)

@inline function Base.getindex(c::ProcessContext, var::Var{SubcontextRef, name}) where {SubcontextRef, name}
    # A field redirected by `Redirect` reads the value of the field it points to, not its `RedirectedVar` marker.
    @inline _var_transform(var, (@inline _follow_reads(c, getproperty(_var_subcontext(c, SubcontextRef), name))))
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
@inline function Base.getindex(c::ProcessContext, var::Var{:_captured_returns, name}) where {name}
    _var_transform(var, get_captured_returns(c)[name])
end
