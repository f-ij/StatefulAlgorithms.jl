
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

"""
    match(a, b) -> Bool

Whether `a` and `b` (algorithms, their types, or matchers) match: their matchers (`match_by`) compared with
`matcher_equals`. Each matcher's method decides from the types where they say enough, so the result is folded while
compiling (a matcher without fields, a numbered `UniquePlanId`), and compares values otherwise (a dynamic `UniquePlanId`).
"""
@inline match(obj1::O1, obj2::O2) where {O1,O2} = matcher_equals(match_by(obj1), match_by(obj2))

"""
    matcher_equals(m1, m2) -> Bool

Whether two matchers, or a matcher and a plain id (a type, a symbol, an `isbits` value), name the same algorithm: what
`match` compares with. Default: `==`, for plain ids. A matcher extends this and never `Base.:(==)`: one equality
function for matchers, and an `==` method that takes any value, or any type, on one side is a new method of Base's `==`
for every type, so loading the package would make Julia throw away (invalidate) the compiled code of everything that
calls `==` on such arguments, Base's own code included.
Extended by: `SimpleId`, `ObjectIDMatcher`, `TypeMatcher`, `ValMatcher`, `MatchAnyOf`, `MatchAny`, `MatchAll`,
`TreeMatcher`, `MultiMatcher` (below); `UniquePlanId` (Identifiable/UniquePlanId/HookExtensions.jl).
"""
@inline matcher_equals(m1, m2) = m1 == m2

"""
    dynamic_match(a, b) -> Bool

`match(a, b)` for code that knows the types only at run time, such as the registry walk comparing every new handle
with the ones before it: untyped, and its matchers compared with `dynamic_equals`, so it compiles once instead of once
for every pair of types. It gives the same answer as `match`.
"""
Base.@nospecializeinfer dynamic_match(@nospecialize(a), @nospecialize(b)) = dynamic_equals(match_by(a), match_by(b))::Bool

"""
    dynamic_equals(m1, m2) -> Bool

`matcher_equals(m1, m2)`, untyped: what `dynamic_match` compares with. A matcher whose `matcher_equals` reads its type
parameters, and so compiles for every pair of types, extends it with an untyped method that gives the same answer.
Default: `matcher_equals`. Extended by: `SimpleId`, `ObjectIDMatcher`, `ValMatcher` (below); `UniquePlanId`
(Identifiable/UniquePlanId/StructDef.jl).
"""
Base.@nospecializeinfer dynamic_equals(@nospecialize(m1), @nospecialize(m2)) = matcher_equals(m1, m2)


### MATCHERS

abstract type AbstractMatcher{A} end
getmatchers(m::AbstractMatcher{A}) where {A} = A
# A matcher matches as itself. Matchers are compared as values (`matcher_equals`), never by their type.
match_by(m::AbstractMatcher) = m

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
matcher_equals(::SimpleId{id1}, ::SimpleId{id2}) where {id1, id2} = id1 == id2
Base.@nospecializeinfer dynamic_equals(@nospecialize(a::SimpleId), @nospecialize(b::SimpleId)) = getmatchers(a) == getmatchers(b)

struct ObjectIDMatcher{id} <: AbstractMatcher{id} end
ObjectIDMatcher(id::UInt64) = ObjectIDMatcher{id}()
ObjectIDMatcher(obj) = ObjectIDMatcher(objectid(obj))
matcher_equals(::ObjectIDMatcher{id1}, ::ObjectIDMatcher{id2}) where {id1, id2} = id1 == id2
Base.@nospecializeinfer dynamic_equals(@nospecialize(a::ObjectIDMatcher), @nospecialize(b::ObjectIDMatcher)) = getmatchers(a) == getmatchers(b)

"""
Matches BOTH with the object type or the match_by of the object type
"""
struct TypeMatcher{T} <: AbstractMatcher{T} end
TypeMatcher(t::Type) = TypeMatcher{t}()
# match_by(tm::TypeMatcher{T}) where T = tm
function matcher_equals(tm::TypeMatcher{T}, a) where T
    if a isa Type
        return a == T || match(a, T)
    else
        return typeof(a) == T || match(typeof(a), T)
    end
end
function matcher_equals(a, tm::TypeMatcher{T}) where T
    if a isa Type
        return a == T || match(a, T)
    else 
        return typeof(a) == T || match(typeof(a), T)
    end
end
function matcher_equals(tm1::TypeMatcher{T1}, tm2::TypeMatcher{T2}) where {T1,T2}
    return T1 == T2 || match(T1, T2)
end

# Match with any isbits value/any type parameter, basically a Val type
struct ValMatcher{V} <: AbstractMatcher{V} end
ValMatcher(v) = ValMatcher{v}()
function matcher_equals(sm::ValMatcher{V}, a) where V
    return matcher_equals(V, a)
end
function matcher_equals(a, sm::ValMatcher{V}) where V
    return matcher_equals(V, a)
end
function matcher_equals(sm1::ValMatcher{V1}, sm2::ValMatcher{V2}) where {V1,V2}
    return V1 == V2
end
Base.@nospecializeinfer dynamic_equals(@nospecialize(a::ValMatcher), @nospecialize(b::ValMatcher)) = getmatchers(a) == getmatchers(b)

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
_any_matches(m, x) = any(p -> matcher_equals(p, x), matcher_parts(m))
matcher_equals(m::MatchAnyOf, x) = _any_matches(m, x)
matcher_equals(x, m::MatchAnyOf) = _any_matches(m, x)
matcher_equals(m::MatchAnyOf, n::MatchAnyOf) = any(p -> _any_matches(m, p), matcher_parts(n))

################################################
##################   HOOKS   ###################
################################################

"""
    map_matchers_of_type(M, obj, f) -> obj

`obj` with every matcher of type `M` in it replaced by `f(matcher)`: what turns the `Unique` ids of a plan or lifetime
into another form (`strip_unique`, `number_unique_ids`, `number_by_keymap_dynamic`, with `M = UniquePlanId`). A matcher
of type `M` is replaced; a type that holds matchers rebuilds itself with the new ones (its type follows them); a tuple
or named tuple maps its elements. Anything else, and a value with no matcher of type `M` changed, is returned as it is
(`===`). Default: `obj`. Untyped, so a plan with new `Unique` handles compiles nothing here.

Extended by: tuples, named tuples, `AbstractMatcher`, `MatchAnyOf` (below); `IdentifiableAlgo` (its matcher, through
`setmatcher`, and its `func`; Identifiable/HookExtensions.jl); `Route`, `Share`, `Redirect` (their endpoints;
RoutingInterface/HookExtensions.jl); `Var` (Context/Vars.jl); `RunIf` (LoopAlgorithms/Interval.jl); the lifetimes with
`Var`s (`Until`, `AtLeast`, `RepeatOrUntil`, `AtLeastAtMost`, each in its file); the plans and what they hold
(`CompositeAlgorithm`, `Routine`, `ThreadedCompositeAlgorithm`, `FinalizedAlgorithm`, `WithWiring` in their files;
`LoopAlgorithm`, `PlanWiring`, `Wiring` in LoopAlgorithms/Interface.jl).
"""
map_matchers_of_type(M::Type, @nospecialize(obj), f) = obj

"""
    map_matchers(obj, f) -> obj

`obj` with every matcher in it replaced by `f(matcher)`: `map_matchers_of_type` for matchers of any type. Not used
yet; the `Unique` id forms use `map_matchers_of_type`, which leaves every other matcher alone.
"""
map_matchers(@nospecialize(obj), f) = map_matchers_of_type(Any, obj, f)

map_matchers_of_type(M::Type, @nospecialize(m::AbstractMatcher), f) = m isa M ? f(m) : m
# A merged state's matcher holds the matchers it merged.
function map_matchers_of_type(M::Type, @nospecialize(m::MatchAnyOf), f)
    parts = matcher_parts(m)
    new = map_matchers_of_type(M, parts, f)
    new === parts && return m
    return new_instance(Core.apply_type(MatchAnyOf, typeof(new)), new)
end
function map_matchers_of_type(M::Type, @nospecialize(t::Tuple), f)
    new = _map_matchers_in_elements(M, t, f)
    return isnothing(new) ? t : Core._apply_iterate(iterate, tuple, new)
end
function map_matchers_of_type(M::Type, @nospecialize(t::NamedTuple), f)
    new = _map_matchers_in_elements(M, t, f)
    return isnothing(new) ? t : NamedTuple{keys(t)}(Core._apply_iterate(iterate, tuple, new))
end

# The elements of `t` mapped, or `nothing` when none changed (then nothing is allocated).
function _map_matchers_in_elements(M::Type, @nospecialize(t), f)
    n = nfields(t)
    for i in 1:n
        old = getfield(t, i)
        new = map_matchers_of_type(M, old, f)
        new === old && continue
        values = Any[getfield(t, j) for j in 1:n]
        values[i] = new
        for j in i+1:n
            values[j] = map_matchers_of_type(M, values[j], f)
        end
        return values
    end
    return nothing
end

"""
    map_matchers_in_fields(M, obj, f, names) -> obj

`obj` with `map_matchers_of_type(M, _, f)` applied to its fields `names`, rebuilt with `replace_fields` when one changed
(each type parameter a changed field is declared as follows it); `obj` itself otherwise. What a type whose type
parameters follow its fields calls in its `map_matchers_of_type` method, naming the fields that can hold matchers.
"""
function map_matchers_in_fields(M::Type, @nospecialize(obj), f, @nospecialize(names::Tuple))
    changed = nothing   # allocated at the first changed field
    values = nothing
    for name in names
        old = getfield(obj, name)
        new = map_matchers_of_type(M, old, f)
        new === old && continue
        isnothing(changed) && (changed = Symbol[]; values = Any[])
        push!(changed, name)
        push!(values, new)
    end
    isnothing(changed) && return obj
    return replace_fields(obj, Tuple(changed), Tuple(values))
end

################################################
#############   NOT USED (KEPT)   ##############
################################################

# Matchers nothing in the package constructs any more: a merged state matches by `MatchAnyOf`, which holds its parts as
# data (`UniquePlanId` carries a uuid). Kept as simple facilities.

struct MatchAny{A} <: AbstractMatcher{A} end
MatchAny(matchers...) = MatchAny(tuple(matchers...))
function matcher_equals(m1::MatchAny, a)
    return any(x -> matcher_equals(x, a), getmatchers(m1))
end
function matcher_equals(a, m1::MatchAny)
    return any(x -> matcher_equals(x, a), getmatchers(m1))
end

struct MatchAll{A} <: AbstractMatcher{A} end
MatchAll(matchers...) = MatchAll(tuple(matchers...))
function matcher_equals(m1::MatchAll, a)
    return all(x -> matcher_equals(x, a), getmatchers(m1))
end
function matcher_equals(a, m1::MatchAll)
    return all(x -> matcher_equals(x, a), getmatchers(m1))
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

@inline function matcher_equals(tm1::TreeMatcher{TID1}, tm2::TreeMatcher{TID2}) where {TID1,TID2}
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

function matcher_equals(mm::MultiMatcher, a)
    return any(x -> matcher_equals(x, a), getmatchers(mm))
end
function matcher_equals(a, mm::MultiMatcher)
    return any(x -> matcher_equals(x, a), getmatchers(mm))
end
function matcher_equals(mm1::MultiMatcher{A}, mm2::MultiMatcher{B}) where {A,B}
    return any(x -> any(y -> matcher_equals(x, y), getmatchers(mm2)), getmatchers(mm1))
end
