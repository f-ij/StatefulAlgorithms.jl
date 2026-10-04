#=
Ids that are different on every run, how to take them apart and rebuild them, and how they are keyed in a
registry's runtime lookup table.

`Unique(f)` gives a handle a random `SimpleId{uuid}()`, so the handle's type is new on every run. `resolve` replaces
such ids by `NormalizedId{k, R}()` (NormalizeIds.jl) and keeps what is needed to rebuild the original id in the
handle's `reconstructor` field, an `IdReconstructor`. Both are `isbits`, and their types do not contain the uuid.
=#

"""
    deconstruct_id(id) -> (IdType, data)

Split an id into its type without data (`SimpleId`) and the data it carries (the uuid), so it can be rebuilt with
`reconstruct_id(IdType, data)`. Extend both for an id type whose handles should be normalized by `resolve`.
"""
deconstruct_id(::SimpleId{data}) where {data} = (SimpleId, data)
deconstruct_id(::ObjectIDMatcher{data}) where {data} = (ObjectIDMatcher, data)

"""
    reconstruct_id(IdType, data) -> id

Rebuild the id that `deconstruct_id` took apart: `reconstruct_id(SimpleId, uuid) === SimpleId{uuid}()`.
"""
reconstruct_id(::Type{SimpleId}, data) = SimpleId{data}()
reconstruct_id(::Type{ObjectIDMatcher}, data) = ObjectIDMatcher{data}()

"""
    IdReconstructor{IdType, T}

What a normalized handle needs to rebuild its original id: the id's type without data as a type parameter
(`SimpleId`), and the data as a field (`data::UUID`). `isbits`, and the same type for every uuid.
"""
struct IdReconstructor{IdType, T}
    data::T
end

function IdReconstructor(id)
    IdType, data = deconstruct_id(id)
    return IdReconstructor{IdType, typeof(data)}(data)
end

reconstructor_idtype(::Type{<:IdReconstructor{IdType}}) where {IdType} = IdType
reconstruct_id(r::IdReconstructor{IdType}) where {IdType} = reconstruct_id(IdType, getfield(r, :data))

"""
    NormalizedId{N, R}

Stands in for the `N`-th random id of a plan (in order of first appearance) while `resolve` runs; `R` is the
`IdReconstructor` type of the original id, whose value the handle keeps in its `reconstructor` field. A matcher type
of its own, so it cannot clash with ids users choose.
"""
struct NormalizedId{N, R} <: AbstractMatcher{N} end

"""
    dynamic_lookup_key(obj)

The key under which `obj` is stored in a registry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`).

Ids that are different on every run are lowered to a `Symbol` naming the id's type and data, for example
`Symbol("StatefulAlgorithms.SimpleId{Base.UUID}_9e27…")`: a new uuid then gives a new key of the same type `Symbol`,
so storing it compiles nothing, and different id types cannot collide. A normalized handle gets the key of its
original id, so the table is right during `resolve` already. Any other matcher is used as it is.
"""
dynamic_lookup_key(obj) = _lowered_matcher(match_by(obj))

function dynamic_lookup_key(sa::IdentifiableAlgo{F, Id, VA, AlgoName, Key, R}) where {F, Id, VA, AlgoName, Key, R<:IdReconstructor}
    return _lowered_id_key(reconstructor_idtype(R), getfield(getfield(sa, :reconstructor), :data))
end

_lowered_matcher(matcher) = matcher
_lowered_matcher(id::Union{SimpleId, ObjectIDMatcher})::Symbol = _lowered_id_key(deconstruct_id(id)...)

_lowered_id_key(IdType, data)::Symbol = Symbol(parentmodule(IdType), ".", nameof(IdType), "{", typeof(data), "}_", data)
