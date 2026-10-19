#=
Matchers lowered to a key of a registry's runtime lookup table (the key type itself, `LookupKey`, is in
Registry/LookupKey.jl): ids that are different on every run become a `Symbol` naming the id's type and data.
=#

"""
    _lowered_matcher(matcher)

The matcher as a lookup-table key: an id that is different on every run (`SimpleId`, `ObjectIDMatcher`, a
`UniquePlanId` in any form) becomes the `Symbol` from `_lowered_id_key`, any other matcher is returned as it is. Used by
`dynamic_lookup_key`.
"""
_lowered_matcher(matcher) = matcher
_lowered_matcher(::SimpleId{data}) where {data} = _lowered_id_key(SimpleId, data)
_lowered_matcher(::ObjectIDMatcher{data}) where {data} = _lowered_id_key(ObjectIDMatcher, data)
_lowered_matcher(id::UniquePlanId)::Symbol = _lowered_id_key(UniquePlanId, origin(id))

"""
    _lowered_id_key(IdType, data) -> Symbol

A `Symbol` naming the id type and its data, e.g. `Symbol("StatefulAlgorithms.SimpleId{Base.UUID}_9e27…")`.
"""
_lowered_id_key(IdType, data)::Symbol = Symbol(parentmodule(IdType), ".", nameof(IdType), "{", typeof(data), "}_", data)
