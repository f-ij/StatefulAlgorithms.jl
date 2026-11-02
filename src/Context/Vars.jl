export Var

"""
    Var(subcontext_ref, :name; transform = nothing, reverse_transform = nothing)
    Var(:name)

A `VarLocation` that is not resolved yet: its storage is the matcher its subcontext is found by.

`Var(subcontext_ref, :name)` makes the location of the variable `name` of a subcontext. `subcontext_ref` refers to
it: an algorithm or state as it was put into the plan (its type, or the instance), or a context key (`:Sensor_1`,
`:_captured_returns`, `:_declared_locals`). With `transform`, reading it gives `transform(value)`;
`reverse_transform` maps a value written back through it onto the field. Read with `context[var]`, used by lifetimes
(`Until(cond, Var(counter, :count))`), and as the source of a wire in `WithWiring` (`From`).

`subcontext_ref` is stored as its matcher (`scref_matcher`) in the `storage` field: a context key as a `KeyMatcher`,
anything else (a type, an instance, a `Unique` handle) as the matcher it is found by. The field's type `M` decides
the read while compiling: a key reads that subcontext, any other matcher the registry entry it matches
(`resolve_scref`); a type reads the first registered algorithm of that type. Only a matcher that carries data (a
`Unique` handle's `UniquePlanId`) takes bytes. The transforms must be plain functions or closures without captured
values, as for routes.
"""
const Var{M<:AbstractMatcher, field, func, reversefunc} = VarLocation{M, field, func, reversefunc}

# Typed: `c[Var(:key, :x)]` in a function is inferred and does not allocate.
Var(subcontext_ref, name::Symbol; transform = nothing, reverse_transform = nothing) =
    _typed_var(scref_matcher(subcontext_ref), name, transform, reverse_transform)
Var(subcontext_ref::IdentifiableAlgo{F, Id, VA, AN, K, Nothing}, name::Symbol; transform = nothing, reverse_transform = nothing) where {F, Id, VA, AN, K} =
    _typed_var(scref_matcher(subcontext_ref), name, transform, reverse_transform)
# A handle whose matcher carries data (a `Unique` handle) has a new type for every uuid: built untyped from its
# `matcher` field (which is what it is found by), so a new handle compiles nothing. The result is not inferred.
Base.@nospecializeinfer function Var(@nospecialize(subcontext_ref::IdentifiableAlgo), name::Symbol; transform = nothing, reverse_transform = nothing)
    matcher = getfield(subcontext_ref, :matcher)
    return new_instance(Core.apply_type(VarLocation, typeof(matcher), name, transform, reverse_transform), matcher)
end
@inline _typed_var(matcher::M, name::Symbol, transform::T, reverse_transform::R) where {M, T, R} =
    Var{M, name, transform, reverse_transform}(matcher)

"""
    reconstruct_var(V) -> the `Var` of type `V`

The `Var` of type `V`, from the type alone: its matcher from the matcher type (`reconstruct_matcher`). Works for a key,
a type, a plain instance and a held `Unique` handle; errors for a stripped or numbered `Unique` handle, whose uuid is
only in the value (reading such a `Var` needs only its type).
"""
reconstruct_var(::Type{Var{M, name, transform, reverse_transform}}) where {M<:AbstractMatcher, name, transform, reverse_transform} =
    Var{M, name, transform, reverse_transform}(reconstruct_matcher(M))
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

"""
    resolve_var_key(var, context) -> the `Var` reading the same variable by its context key

`var` with its matcher replaced by the key of the subcontext it reads (`KeyMatcher{key}`), found from `context`'s
registry while compiling (`resolve_scref`). Reading the result needs no registry: the lifetime's `Var`s get their keys
before the loop (`resolve_var_keys`), so the stop check before every step does not load the registry. A `Var` that
already has a key, or anything else a lifetime reads (a context key as a `Symbol`), is returned as it is, without
reading the registry; so is a `Var` in a context without a registry.
"""
@inline resolve_var_key(var::V, context::C) where {V, C} = var
@inline resolve_var_key(var::Var{KeyMatcher{key}}, context::ProcessContext) where {key} = var
@inline function resolve_var_key(var::Var{M}, context::ProcessContext) where {M<:AbstractMatcher}
    registry = getregistry(context)
    isnothing(registry) && return var
    return _var_with_key(var, Val(resolve_scref(registry, M, nothing, "Var subcontext")))
end
@inline _var_with_key(::Var{M, name, transform, reverse_transform}, ::Val{key}) where {M<:AbstractMatcher, name, transform, reverse_transform, key} =
    Var{KeyMatcher{key}, name, transform, reverse_transform}(KeyMatcher{key}())

@inline _var_transform(::Var{M, N, nothing}, value) where {M<:AbstractMatcher, N} = value
@inline _var_transform(::Var{M, N, transform}, value) where {M<:AbstractMatcher, N, transform} = transform(value)

@inline function Base.getindex(c::ProcessContext, var::Var{M, name}) where {M<:AbstractMatcher, name}
    # A field redirected by `Redirect` reads the value of the field it points to, not its `RedirectedVar` marker.
    @inline _var_transform(var, (@inline _follow_reads(c, getproperty(_var_subcontext(c, M), name))))
end

"""The value stored at the state location `subcontext.field` of `c`, as stored: what a `ReadFrom` goes on with."""
@inline stored_value_at(c::ProcessContext, ::VarLocation{StatePartition{subcontext}, field}) where {subcontext, field} =
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
