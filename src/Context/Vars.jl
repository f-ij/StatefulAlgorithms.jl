export Var

"""
    Var(subcontext_ref, :name; transform = nothing, reverse_transform = nothing)
    Var(:name)

A `VarLocation` that is not resolved yet: its storage is the matcher its subcontext is found by.

`Var(subcontext_ref, :name)` makes the location of the variable `name` of a subcontext. `subcontext_ref` refers to
it: an algorithm or state as it was put into the plan (its type, or the instance), or a context key (`:Sensor_1`,
`:_captured_returns`, `:_declared_locals`). A key needs no registry, so its location is resolved already (a
`VarLocation{<:Partition}`, not a `Var`); anything else is stored as the matcher it is found by (`scref_matcher`), in
the `storage` field. With `transform`, reading it gives `transform(value)`; `reverse_transform` maps a value written
back through it onto the field. Read with `context[location]`, used by lifetimes (`Until(cond, Var(counter, :count))`),
and as the source of a wire in `WithWiring` (`From`).

A `Var` is read through the registry entry its matcher matches (`resolve_scref`, while compiling); a type reads the
first registered algorithm of that type. Only a matcher that carries data (a `Unique` handle's `UniquePlanId`) takes
bytes. The transforms must be plain functions or closures without captured values, as for routes.
"""
const Var{M<:AbstractMatcher, field, func, reversefunc} = VarLocation{M, field, func, reversefunc}

# Typed: `c[Var(:key, :x)]` in a function is inferred and does not allocate.
function Var(key::Symbol, name::Symbol; transform = nothing, reverse_transform = nothing)
    partition = context_partition(key)
    return VarLocation{typeof(partition), name, transform, reverse_transform}(partition)
end
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
    reconstruct_var(L) -> the location of type `L`

The location of type `L`, from the type alone: a resolved one from its partition, a `Var` from its matcher type
(`reconstruct_matcher`). Works for a key, a type, a plain instance and a held `Unique` handle; errors for a stripped or
numbered `Unique` handle, whose uuid is only in the value (reading such a `Var` needs only its type).
"""
reconstruct_var(::Type{L}) where {L<:VarLocation{<:Partition}} = L()
reconstruct_var(::Type{Var{M, name, transform, reverse_transform}}) where {M<:AbstractMatcher, name, transform, reverse_transform} =
    Var{M, name, transform, reverse_transform}(reconstruct_matcher(M))
Var(name::Symbol) = Var(:_captured_returns, name)

"""
Return the subcontext a `Var` refers to: the registry entry its matcher matches (resolved as a route endpoint, so the
key is found at compile time).
"""
@inline function _var_subcontext(c::ProcessContext, ::Type{M}) where {M<:AbstractMatcher}
    reg = getregistry(c)
    isnothing(reg) && error("Cannot look up a `Var`'s subcontext without a registry in this context.")
    return getproperty(c, resolve_scref(reg, M, nothing, "Var subcontext"))
end

"""
    resolve_var(var, context) -> the location `var` resolves to

`var`'s resolved location: its matcher replaced by the partition of the subcontext it reads
(`StatePartition{key}`), found from `context`'s registry while compiling (`resolve_scref`). Reading the result needs no
registry: the lifetime's `Var`s are resolved before the loop (`resolve_vars`), so the stop check before every step
does not load the registry. A location that is resolved already, or anything else a lifetime reads, is returned as it
is, without reading the registry; so is a `Var` in a context without a registry.
"""
@inline resolve_var(var::V, context::C) where {V, C} = var
@inline function resolve_var(var::Var{M}, context::ProcessContext) where {M<:AbstractMatcher}
    registry = getregistry(context)
    isnothing(registry) && return var
    return _var_location(var, Val(resolve_scref(registry, M, nothing, "Var subcontext")))
end
@inline _var_location(::Var{M, name, transform, reverse_transform}, ::Val{key}) where {M<:AbstractMatcher, name, transform, reverse_transform, key} =
    VarLocation{StatePartition{key}, name, transform, reverse_transform}(StatePartition{key}())

@inline _var_transform(::VarLocation{S, N, nothing}, value) where {S, N} = value
@inline _var_transform(::VarLocation{S, N, transform}, value) where {S, N, transform} = transform(value)

@inline function Base.getindex(c::ProcessContext, var::Var{M, name}) where {M<:AbstractMatcher, name}
    # A field redirected by `Redirect` reads the value of the field it points to, not its `RedirectedVar` marker.
    @inline _var_transform(var, (@inline _follow_reads(c, getproperty(_var_subcontext(c, M), name))))
end

"""
The value stored at the location `subcontext.field` of `c`, as stored: what a `ReadFrom` goes on with. In the context a
lifetime reads (`final_context`), the runtime partitions are subcontexts too, so both kinds are read the same way.
"""
@inline stored_value_at(c::ProcessContext, ::VarLocation{P, field}) where {P<:Partition, field} =
    @inline getproperty((@inline getproperty(c, partition_name(P))), field)

"""
`c[location]`: the value at a resolved location of `c`, following storage wrappers (a redirect, a declared local's
slot), through its transform.
"""
@inline Base.getindex(c::ProcessContext, location::VarLocation{P}) where {P<:Partition} =
    @inline _var_transform(location, (@inline _follow_reads(c, (@inline stored_value_at(c, location)))))

@inline function Base.getindex(c::ProcessContext, vars::VarLocation...)
    ntuple(Val(length(vars))) do i
        @inline getindex(c, vars[i])
    end
end

@inline function Base.getindex(c::SubContext, vars::Var...)
    ntuple(Val(length(vars))) do i
        getindex(c, vars[i])
    end
end

