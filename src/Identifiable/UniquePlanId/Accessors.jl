#=
Getters and setters of the plan's `UniqueKeyMap` in a registry, a context or a plan: `getkeymap` reads it; `with_keymap`
and `strip_keymap` put it in and take it out untyped (made at run time, compiling nothing per uuid);
`strip_keymap_typed` takes it out typed, for code whose types have the map (`InlineProcess`). None is a hook. Included
after Context/, as the typed method takes a `ProcessContext`.
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
    x isa ProcessContext && return getfield(x, :reg)
    return nothing
end

"""
    with_keymap(x, keymap) -> x

`x` (a registry, a context, a `LoopAlgorithm` or `FinalizedAlgorithm`) with `keymap` (a `UniqueKeyMap` or `nothing`)
as its registry's map. Same entries, subcontexts and plan, not copies; anything else as it is. Untyped: made at run
time, compiling nothing per uuid.
"""
Base.@nospecializeinfer function with_keymap(@nospecialize(x), @nospecialize(keymap))
    # Fields read with `getfield` only, as in `_registry_field`.
    if x isa NameSpaceRegistry
        getfield(x, :keymap) === keymap && return x
        entries = getfield(x, :entries)
        return new_instance(Core.apply_type(NameSpaceRegistry, typeof(entries), typeof(keymap)), entries, keymap)
    elseif x isa ProcessContext
        reg = getfield(x, :reg)
        reg isa NameSpaceRegistry || return x
        newreg = with_keymap(reg, keymap)
        newreg === reg && return x
        subcontexts = getfield(x, :subcontexts)
        return new_instance(Core.apply_type(ProcessContext, typeof(subcontexts), typeof(newreg)), subcontexts, newreg)
    elseif x isa FinalizedAlgorithm
        inner = with_keymap(getfield(x, :inner), keymap)
        inner === getfield(x, :inner) && return x
        final = getfield(x, :final)
        return new_instance(Core.apply_type(FinalizedAlgorithm, typeof(inner), typeof(final)), inner, final)
    elseif x isa LoopAlgorithm
        reg = getfield(x, :reg)
        reg isa NameSpaceRegistry || return x
        newreg = with_keymap(reg, keymap)
        newreg === reg && return x
        p = typeof(x).parameters    # {Plan, O, R, id}
        T = Core.apply_type(LoopAlgorithm, p[1], p[2], typeof(newreg), p[4])
        return new_instance(T, getfield(x, :plan), getfield(x, :options), newreg)
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
    strip_keymap_typed(x) -> x without its registry's map

`strip_keymap` for code typed on the map (a method of `InlineProcess`, whose plan and context have it in their types):
the result's type is known where it is called, so that code stays inferred. For a context: same subcontexts, the
registry without the map; for a `LoopAlgorithm`: same plan and options, the registry without the map. Anything else, or a
registry without a map, as it is.
"""
@inline function strip_keymap_typed(c::ProcessContext{D, NameSpaceRegistry{E, M}}) where {D, E, M}
    M === Nothing && return c
    newreg = NameSpaceRegistry{E, Nothing}(getfield(getfield(c, :reg), :entries), nothing)
    return ProcessContext{D, NameSpaceRegistry{E, Nothing}}(getfield(c, :subcontexts), newreg)
end
@inline function strip_keymap_typed(la::LoopAlgorithm{Plan, O, NameSpaceRegistry{E, M}, id}) where {Plan, O, E, M, id}
    M === Nothing && return la
    newreg = NameSpaceRegistry{E, Nothing}(getfield(getfield(la, :reg), :entries), nothing)
    return LoopAlgorithm{Plan, O, NameSpaceRegistry{E, Nothing}, id}(getfield(la, :plan), getfield(la, :options), newreg)
end
@inline strip_keymap_typed(x) = x
