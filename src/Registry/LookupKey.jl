#=
Keys of a registry entry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`), which finds the algorithms that
are not found by their type (`isstaticallyfindable` is false). The id-specific part of a key, lowering random ids to a
`Symbol`, is in Identifiable/LoweredIds.jl (`_lowered_matcher`, `_lowered_id_key`).
=#

"""
    LookupKey(key)

A key of a registry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`): `key` (a type, a `Symbol`, an
`isbits` value, ...) wrapped in one concrete type, equal and hashed as `key` itself. Lookups behave as with `key`;
the table's methods (`setindex!`, `get`, `delete!`) are compiled once for `LookupKey`, not once per key type (a
`Dict{Any}` compiles `setindex!` again for every type used as a key, `Lin{1}`, `Lin{2}`, ...). Prints as `key`.

The field is `Any` on purpose: a `LookupKey{T}` would be a different key type for every `T` again, and the table
would compile per key type as before.
"""
struct LookupKey
    key::Any
end
Base.isequal(a::LookupKey, b::LookupKey) = isequal(a.key, b.key)
Base.hash(k::LookupKey, h::UInt) = hash(k.key, h)
Base.print(io::IO, k::LookupKey) = print(io, k.key)
Base.show(io::IO, k::LookupKey) = show(io, k.key)

"""
    dynamic_lookup_key(obj) -> LookupKey

The key under which `obj` is stored in a registry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`), as a
`LookupKey`: the lowered matcher of `obj` (`match_by`).

Ids that are different on every run are lowered to a `Symbol` naming the id's type and data, for example
`Symbol("StatefulAlgorithms.SimpleId{Base.UUID}_9e27…")`: a new uuid then gives a new key of the same type `Symbol`,
so storing it compiles nothing, and different id types cannot collide. A `Unique` handle is keyed by its uuid, the same
for every form of its `UniquePlanId` (held by the user, stripped, or numbered). Any
other matcher is used as it is.
"""
dynamic_lookup_key(obj) = LookupKey(_lowered_matcher(match_by(obj)))
