export Var

################################################
###################   TYPE   ###################
################################################

"""
    Var(subcontext_ref, :name; transform = nothing)
    Var(:name)

Selects the variable `name` of a subcontext. `subcontext_ref` refers to it: an algorithm or
state as it was put into the plan (its type, or the instance), or a context key (`:Sensor_1`,
`:_captured_returns`, `:_declared_locals`). With
`transform`, reading it gives `transform(value)`. Read with `context[var]`, used by lifetimes
(`Until(cond, Var(counter, :count))`), and as the source of a wire in `WithWiring` (`From`).

`subcontext_ref` is stored as its matcher (`scref_matcher`) in the `matcher` field: a context key as a `KeyMatcher`,
anything else (a type, an instance, a `Unique` handle) as the matcher it is found by. A key reads that subcontext,
any other matcher the registry entry it matches, compared as values (`resolve_scref`; decided while compiling when
the types decide it: a key, a matcher without fields, a numbered id); a type reads the first registered algorithm of that type. Only a matcher that carries data (a
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

"""
    reconstruct_var(V) -> the `Var` of type `V`

The `Var` of type `V`, from the type alone: its matcher from the matcher type (`reconstruct_matcher`). Works for a key,
a type, a plain instance and a held `Unique` handle; errors for a stripped or numbered `Unique` handle, whose uuid is
only in the value (reading such a `Var` needs only its type).
"""
reconstruct_var(::Type{Var{M, name, transform}}) where {M, name, transform} =
    Var{M, name, transform}(reconstruct_matcher(M))
Var(name::Symbol) = Var(:_captured_returns, name)

################################################
#################   RESOLVE   ##################
################################################

"""
Return the subcontext a `Var` refers to: the one its `KeyMatcher` names, or the registry entry its matcher matches,
compared as values (resolved as a route endpoint; folded while compiling when the types decide it, as for a numbered
id).
"""
@inline _var_subcontext(c::ProcessContext, ::Var{KeyMatcher{key}}) where {key} = c[key]
@inline function _var_subcontext(c::ProcessContext, var::Var{M}) where {M<:AbstractMatcher}
    reg = getregistry(c)
    isnothing(reg) && error("Cannot look up a `Var`'s subcontext without a registry in this context.")
    return getproperty(c, resolve_scref(reg, M, getfield(var, :matcher), "Var subcontext"))
end

"""
    resolve_var_key(var, registry) -> the `Var` reading the same variable by its context key

`var` with its matcher replaced by the key of the subcontext it reads (`KeyMatcher{key}`), found in `registry` (the
plan's) by its matcher's value (`resolve_scref`). Reading the result needs no registry: the loop's context has none
(`drop_registry`), so a lifetime's `Var`s get their keys before the stop check reads them (`resolve_var_keys`). A `Var`
that already has a key, or anything else a lifetime reads, is returned as it is; so is any `Var` when there is no
registry (`nothing`).
"""
@inline resolve_var_key(var::V, registry::R) where {V, R} = var
@inline resolve_var_key(var::Var{KeyMatcher{key}}, registry::R) where {key, R<:NameSpaceRegistry} = var
@inline resolve_var_key(var::Var{M}, registry::R) where {M<:AbstractMatcher, R<:NameSpaceRegistry} =
    _var_with_key(var, Val(resolve_scref(registry, M, getfield(var, :matcher), "Var subcontext")))
@inline _var_with_key(::Var{M, name, transform}, ::Val{key}) where {M, name, transform, key} =
    Var{KeyMatcher{key}, name, transform}(KeyMatcher{key}())

@inline _var_transform(::Var{M, N, nothing}, value) where {M, N} = value
@inline _var_transform(::Var{M, N, transform}, value) where {M, N, transform} = transform(value)

################################################
###################   READ   ###################
################################################

@inline function Base.getindex(c::ProcessContext, var::Var{M, name}) where {M, name}
    # A field redirected by `Redirect` reads the value of the field it points to, not its `RedirectedVar` marker.
    @inline _var_transform(var, (@inline _follow_reads(c, getproperty(_var_subcontext(c, var), name))))
end

"""What is literally stored in the state field `subcontext.field` of `c`, no hook asked (see `getproperty_raw`)."""
@inline getproperty_raw(c::ProcessContext, ::VarLocation{:state, subcontext, field}) where {subcontext, field} =
    @inline getproperty((@inline getproperty(c, subcontext)), field)

@inline function Base.getindex(c::ProcessContext, vars::Var...)
    ntuple(Val(length(vars))) do i
        @inline getindex(c, vars[i])
    end
end

"""
Read a DSL runtime variable selector from `ProcessContext._captured_returns`.
"""
@inline function Base.getindex(c::ProcessContext, var::Var{KeyMatcher{:_captured_returns}, name}) where {name}
    _var_transform(var, get_captured_returns(c)[name])
end

################################################
##############   HOOK EXTENSIONS   #############
################################################

# Its matcher replaced (`map_matchers_of_type`, Matching.jl); `M` follows it.
Base.@nospecializeinfer map_matchers_of_type(M::Type, @nospecialize(v::Var), f) = map_matchers_in_fields(M, v, f, (:matcher,))
