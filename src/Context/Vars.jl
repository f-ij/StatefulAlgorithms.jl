export Var

"""
    Var(subcontext_ref, :name; transform = nothing)
    Var(:name)

Selects the variable `name` of a subcontext. `subcontext_ref` refers to it: an algorithm or
state as it was put into the plan (its type, or the instance), or a context key (`:Sensor_1`,
`:_captured_returns`, `:_declared_locals`). With
`transform`, reading it gives `transform(value)`. Read with `context[var]`, used by lifetimes
(`Until(cond, Var(counter, :count))`), and as the source of a wire in `WithWiring` (`From`).

Everything is type data. A reference that cannot be a type parameter (an instance with
non-plain-data fields, e.g. a `Vector`) is kept as the matcher the registry identifies it by;
the transform must be a plain function or a closure without captured values, as for routes.
"""
struct Var{SubcontextRef, name, transform} end

Var(subcontext_ref, name::Symbol; transform = nothing) = Var{_stored_subcontext_ref(subcontext_ref), name, transform}()
Var(name::Symbol) = Var{:_captured_returns, name, nothing}()

"""A subcontext reference as `Var` stores it in its type: as given, or as its registry matcher."""
_stored_subcontext_ref(ref::Symbol) = ref
_stored_subcontext_ref(ref) = (ref isa Type || isbits(ref)) ? ref : scref_match(ref)

"""The subcontext a `Var` refers to: by key, by registry lookup, or by the matcher it was stored as."""
@inline _var_subcontext(c::ProcessContext, ref) = c[ref]
@inline function _var_subcontext(c::ProcessContext, ::Type{M}) where {M<:AbstractMatcher}
    reg = getregistry(c)
    isnothing(reg) && error("Cannot look up a `Var`'s subcontext without a registry in this context.")
    return getproperty(c, getkey(get_by_matcher(reg, M())))
end

@inline _var_transform(::Var{E, N, nothing}, value) where {E, N} = value
@inline _var_transform(::Var{E, N, transform}, value) where {E, N, transform} = transform(value)

@inline function Base.getindex(c::ProcessContext, var::Var{SubcontextRef, name}) where {SubcontextRef, name}
    # A field replaced by `Replace` reads the value of the field it points to, not its `ReplacedVar` marker.
    @inline _var_transform(var, (@inline context_value(c, getproperty(_var_subcontext(c, SubcontextRef), name))))
end

"""
    context_value(c, stored)

Return the value a stored field reads as: `stored` itself, or for a
`ReplacedVar` marker the value at the location it points to in `c`.
"""
@inline context_value(c::ProcessContext, stored) = stored
@inline function context_value(c::ProcessContext, ::ReplacedVar{VL}) where {VL}
    @inline c[Var(get_subcontextname(VL), get_originalname(VL))]
end

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
