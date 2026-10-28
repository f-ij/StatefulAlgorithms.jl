
"""
Standard behavior: types match by themselves, objects match by their type

Reminder: This is not how ProcessEntities match
"""
# match_by(obj::O) where O = match_by(typeof(obj))
match_by(o::O) where O = error("No match_by method defined for value of type $O, got object $o")
"""
Type matching needs to be exlicitly extended
"""
match_by(t::Type{T}) where T = error("No match_by method defined for type $T")

function match(obj1::O1, obj2::O2) where {O1,O2}
    id1 = obj1 isa AbstractMatcher ? obj1 : match_by(obj1)
    id2 = obj2 isa AbstractMatcher ? obj2 : match_by(obj2)
    return id1 == id2
end


### MATCHERS

abstract type AbstractMatcher{A} end
getmatchers(m::AbstractMatcher{A}) where {A} = A
# A matcher, or a matcher type (the type-level id of a handle whose matcher carries data, `static_id`), matches as itself.
match_by(m::AbstractMatcher) = m
match_by(T::Type{<:AbstractMatcher}) = T

"""
    static_id(matcher) -> value or type

The part of a handle's matcher that goes into the handle's type (`IdentifiableAlgo`'s `Id` parameter): a matcher
without fields (`SimpleId{x}()`) is its own type-level id; a matcher that carries data (`UniquePlanId`) has its type
there and its value in the handle's `matcher` field. Any other id (a type, an `isbits` value) is itself.
"""
static_id(id) = id
static_id(m::AbstractMatcher) = Base.issingletontype(typeof(m)) ? m : typeof(m)

"""Whether the matcher `m` carries data its type does not hold (`UniquePlanId`), so a holder keeps it as a value."""
carries_data(m) = static_id(m) !== m
struct SimpleId{id} <: AbstractMatcher{id} end
SimpleId() = SimpleId{uuid4()}()
SimpleId(id) = SimpleId{id}()
Base.:(==)(::SimpleId{id1}, ::SimpleId{id2}) where {id1, id2} = id1 == id2

struct ObjectIDMatcher{id} <: AbstractMatcher{id} end
ObjectIDMatcher(id::UInt64) = ObjectIDMatcher{id}()
ObjectIDMatcher(obj) = ObjectIDMatcher(objectid(obj))
Base.:(==)(::ObjectIDMatcher{id1}, ::ObjectIDMatcher{id2}) where {id1, id2} = id1 == id2

"""
Matches BOTH with the object type or the match_by of the object type
"""
struct TypeMatcher{T} <: AbstractMatcher{T} end
TypeMatcher(t::Type) = TypeMatcher{t}()
# match_by(tm::TypeMatcher{T}) where T = tm
function Base.:(==)(tm::TypeMatcher{T}, a) where T
    if a isa Type
        return a == T || match(a, T)
    else
        return typeof(a) == T || match(typeof(a), T)
    end
end
function Base.:(==)(a, tm::TypeMatcher{T}) where T
    if a isa Type
        return a == T || match(a, T)
    else 
        return typeof(a) == T || match(typeof(a), T)
    end
end
function Base.:(==)(tm1::TypeMatcher{T1}, tm2::TypeMatcher{T2}) where {T1,T2}
    return T1 == T2 || match(T1, T2)
end

# Match with any isbits value/any type parameter, basically a Val type
struct ValMatcher{V} <: AbstractMatcher{V} end
ValMatcher(v) = ValMatcher{v}()
# match_by(sm::Union{ValMatcher{V}, Type{ValMatcher{V}}}) where V = V
function Base.:(==)(sm::Union{ValMatcher{V}, Type{ValMatcher{V}}}, a) where V
    return V == a
end
function Base.:(==)(a, sm::Union{ValMatcher{V}, Type{ValMatcher{V}}}) where V
    return V == a
end
function Base.:(==)(sm1::ValMatcher{V1}, sm2::ValMatcher{V2}) where {V1,V2}
    return V1 == V2
end

"""
    KeyMatcher(key)

The subcontext with SCKey `key` (`:Sensor_1`, `:_captured_returns`), as a matcher: the key in the type, no bytes. What a
`Var` of a context key holds; it names a subcontext directly, so it is never looked up in a registry.
"""
struct KeyMatcher{key} <: AbstractMatcher{key} end
KeyMatcher(key::Symbol) = KeyMatcher{key}()

"""
    reconstruct_matcher(M) -> the matcher of type `M`

The matcher of type `M`, from the type alone. A matcher without fields (`KeyMatcher{k}`, `TypeMatcher{T}`,
`SimpleId{id}`, ...) is the only instance of its type. A matcher with data can be reconstructed only where its type
holds that data; `UniquePlanId` adds a method (a held one has its uuid in the type). Errors otherwise.
"""
function reconstruct_matcher(::Type{M}) where {M}
    Base.issingletontype(M) && return M.instance
    error("Cannot reconstruct a matcher of type $M from its type: it holds data the type does not.")
end

"""
    MatchAnyOf(matchers::Tuple)

Matches what any of `matchers` matches, held as data (a `MatchAny` holds them in its type). Used for a state merged
from several (`@merge`), whose matchers may carry data (`UniquePlanId`); its type holds only their types.
"""
struct MatchAnyOf{T<:Tuple} <: AbstractMatcher{T}
    matchers::T
end
matcher_parts(m::MatchAnyOf) = getfield(m, :matchers)
matcher_parts(::Type{MatchAnyOf{T}}) where {T} = Tuple(T.parameters)
_any_matches(m, x) = any(p -> p == x, matcher_parts(m))
Base.:(==)(m::MatchAnyOf, x) = _any_matches(m, x)
Base.:(==)(x, m::MatchAnyOf) = _any_matches(m, x)
Base.:(==)(m::MatchAnyOf, n::MatchAnyOf) = any(p -> _any_matches(m, p), matcher_parts(n))

################################################
##################   HOOKS   ###################
################################################

"""
    matches_type(value, M) -> Bool

Whether the matcher value `value` (an algorithm's `match_by`) is matched by the matcher type `M` (a stored SCRef,
`scref_match`). Default `value isa M`; a matcher type as the value (a handle type's id) by `<:`.
Extended by: `ValMatcher`, `MatchAnyOf`, `MatchAny` (below), `UniquePlanId` (Identifiable/UniquePlanId/HookExtensions.jl).
"""
matches_type(value, M) = value isa M
matches_type(value::Type, M) = value <: M
matches_type(value, ::Type{<:ValMatcher{V}}) where {V} = value == V || value isa ValMatcher{V}
# A merged state's matcher matches if any of its parts does.
matches_type(value::Union{MatchAnyOf, Type{<:MatchAnyOf}}, M) = any(m -> matches_type(m, M), matcher_parts(value))

################################################
#############   NOT USED (KEPT)   ##############
################################################

# Matchers nothing in the package constructs any more: a merged state matches by `MatchAnyOf`, which holds its parts as
# data (`UniquePlanId` carries a uuid). Kept as simple facilities.

struct MatchAny{A} <: AbstractMatcher{A} end
MatchAny(matchers...) = MatchAny(tuple(matchers...))
function Base.:(==)(m1::MatchAny, a)
    return any(x -> x == a, getmatchers(m1))
end
function Base.:(==)(a, m1::MatchAny)
    return any(x -> x == a, getmatchers(m1))
end
matches_type(value::MatchAny, M) = any(m -> matches_type(m, M), getmatchers(value))

struct MatchAll{A} <: AbstractMatcher{A} end
MatchAll(matchers...) = MatchAll(tuple(matchers...))
function Base.:(==)(m1::MatchAll, a)
    return all(x -> x == a, getmatchers(m1))
end
function Base.:(==)(a, m1::MatchAll)
    return all(x -> x == a, getmatchers(m1))
end

"""
Match with any parent nodes but not other siblings
"""
struct TreeMatcher{A} <: AbstractMatcher{A} end
get_tid(tm::TreeMatcher{TID}) where TID = tuple(TID.parameters...)

function TreeMatcher(id = uuid4())
    if id isa Tuple
        return TreeMatcher{Tuple{id...}}()
    else
        return TreeMatcher{Tuple{id}}()
    end
end

getchild(tm::TreeMatcher{TID}, id = uuid4()) where TID = TreeMatcher((get_tid(tm)...,id))

@inline function Base.:(==)(tm1::TreeMatcher{TID1}, tm2::TreeMatcher{TID2}) where {TID1,TID2}
    ids1 = get_tid(tm1)
    ids2 = get_tid(tm2)

    l1 = length(ids1)
    l2 = length(ids2)
    if l1 == l2
        return ids1 == ids2
    elseif l1 < l2
        return ids1 == ids2[1:l1]
    else
        return ids1[1:l2] == ids2
    end
end

struct MultiMatcher{A} <: AbstractMatcher{A} end
function getmatchers(mm::MultiMatcher{A}) where A
    return A
end
"""
Destructure any multi matchers and flatten them into a single tuple of matchers
"""
function MultiMatcher(matchers...)
    flat_matchers = []
    for m in matchers
        if m isa MultiMatcher
            append!(flat_matchers, getmatchers(m))
        else
            push!(flat_matchers, m)
        end
    end
    MultiMatcher(tuple(flat_matchers...))
end

function Base.:(==)(mm::MultiMatcher, a)
    return any(x -> x == a, getmatchers(mm))
end
function Base.:(==)(a, mm::MultiMatcher)
    return any(x -> x == a, getmatchers(mm))
end
function Base.:(==)(mm1::MultiMatcher{A}, mm2::MultiMatcher{B}) where {A,B}
    return any(x -> any(y -> x == y, getmatchers(mm2)), getmatchers(mm1))
end
