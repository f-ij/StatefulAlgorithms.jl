#=
The plan's `UniqueKeyMap` put into a context and taken out of it, typed: for a handle whose type has the map (`Process`,
`InlineProcess`). The untyped versions are `with_keymap` and `strip_keymap` (UniqueKeyMap.jl). After Context/, as they
take a `ProcessContext`.
=#
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

