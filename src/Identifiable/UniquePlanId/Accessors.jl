#=
Getters and setters of the plan's `UniqueKeyMap` in a registry, a context or a plan: `getkeymap` reads it;
`with_keymap` and `strip_keymap` put it in and take it out untyped (made at run time, compiling nothing per uuid);
`attach_keymap` and `detach_keymap` do the same typed, for a handle whose type has the map (`Process`,
`InlineProcess`). After Context/, as the typed ones take a `ProcessContext`.
=#

"""
    getkeymap(x) -> UniqueKeyMap or nothing

The `UniqueKeyMap` in the registry of `x` (a registry, a context, a plan); `nothing` when it has none. Untyped.
"""
Base.@nospecializeinfer function getkeymap(@nospecialize(x))
    reg = _registry_field(x)
    return reg isa NameSpaceRegistry ? getfield(reg, :keymap) : nothing
end

# The registry of `x`, read with `getfield` only: the plans and contexts here have the map in their types, and a call
# of an accessor on them would compile once for every new set of `Unique` handles.
Base.@nospecializeinfer function _registry_field(@nospecialize(x))
    x isa NameSpaceRegistry && return x
    x isa FinalizedAlgorithm && return _registry_field(getfield(x, :inner))
    x isa LoopAlgorithm && return getfield(x, :reg)
    if x isa ProcessContext
        ref = getfield(x, :reg)
        return ref isa Base.RefValue ? ref[] : nothing
    end
    return nothing
end

"""
    with_keymap(x, keymap) -> x

`x` (a registry, a context, a `LoopAlgorithm` or `FinalizedAlgorithm`) with `keymap` (a `UniqueKeyMap` or `nothing`)
as its registry's map: in a plan, both its registry and its persistent context's. Same entries, subcontexts and plan,
not copies; anything else as it is. Untyped: made at run time, compiling nothing per uuid.
"""
Base.@nospecializeinfer function with_keymap(@nospecialize(x), @nospecialize(keymap))
    # Fields read with `getfield` only, as in `_registry_field`.
    if x isa NameSpaceRegistry
        getfield(x, :keymap) === keymap && return x
        entries = getfield(x, :entries)
        return new_instance(Core.apply_type(NameSpaceRegistry, typeof(entries), typeof(keymap)), entries, keymap)
    elseif x isa ProcessContext
        ref = getfield(x, :reg)
        ref isa Base.RefValue || return x
        reg = with_keymap(ref[], keymap)
        reg === ref[] && return x
        newref = new_instance(Core.apply_type(Base.RefValue, typeof(reg)), reg)
        subcontexts = getfield(x, :subcontexts)
        return new_instance(Core.apply_type(ProcessContext, typeof(subcontexts), typeof(newref)), subcontexts, newref)
    elseif x isa FinalizedAlgorithm
        inner = with_keymap(getfield(x, :inner), keymap)
        final = getfield(x, :final)
        return new_instance(Core.apply_type(FinalizedAlgorithm, typeof(inner), typeof(final)), inner, final)
    elseif x isa LoopAlgorithm
        reg = getfield(x, :reg)
        reg isa NameSpaceRegistry || return x
        reg = with_keymap(reg, keymap)
        context = with_keymap(getfield(x, :context), keymap)
        p = typeof(x).parameters    # {Plan, O, R, C, Inits, Overrides, id}
        T = Core.apply_type(LoopAlgorithm, p[1], p[2], typeof(reg), typeof(context), p[5], p[6], p[7])
        return new_instance(T, getfield(x, :plan), getfield(x, :options), reg, context, getfield(x, :inits), getfield(x, :overrides))
    end
    return x
end

"""
    strip_keymap(x) -> x

`x` without its registry's `UniqueKeyMap` (`with_keymap(x, nothing)`): what `init` and the loop compile for, so a new
set of `Unique` handles compiles nothing again.
"""
Base.@nospecializeinfer strip_keymap(@nospecialize(x)) = with_keymap(x, nothing)

"""
    attach_keymap(context, keymap) -> context with `keymap` as its registry's map

`with_keymap` for a typed handle: the context's type and the map's type say the result's type, so it is inferred
(`context(ip)` stays inferred). Same subcontexts and entries, a new registry and `Ref`. A value that is not a context
with a registry, or no map (`nothing`), as it is.
"""
@inline function attach_keymap(c::ProcessContext{D, Base.RefValue{NameSpaceRegistry{E, M}}}, keymap::K) where {D, E, M, K<:UniqueKeyMap}
    reg = getfield(c, :reg)[]
    newreg = NameSpaceRegistry{E, K}(getfield(reg, :entries), keymap)
    return ProcessContext{D, Base.RefValue{NameSpaceRegistry{E, K}}}(getfield(c, :subcontexts), Ref(newreg))
end
@inline attach_keymap(x, ::Nothing) = x
@inline attach_keymap(x, keymap::UniqueKeyMap) = with_keymap(x, keymap)

"""
    detach_keymap(context) -> context without its registry's map

`strip_keymap` for a typed handle: inferred from the context's type (a context the user got back from `context(ip)` and
gives to `run(ip; context)`). A value that is not a context with a registry as it is.
"""
@inline function detach_keymap(c::ProcessContext{D, Base.RefValue{NameSpaceRegistry{E, M}}}) where {D, E, M}
    M === Nothing && return c
    reg = getfield(c, :reg)[]
    newreg = NameSpaceRegistry{E, Nothing}(getfield(reg, :entries), nothing)
    return ProcessContext{D, Base.RefValue{NameSpaceRegistry{E, Nothing}}}(getfield(c, :subcontexts), Ref(newreg))
end
@inline detach_keymap(x) = x

