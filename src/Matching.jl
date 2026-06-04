
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
struct SimpleId{id} <: AbstractMatcher{id} end
SimpleId() = SimpleId{uuid4()}()
SimpleId(id) = SimpleId{id}()
Base.:(==)(::SimpleId{id1}, ::SimpleId{id2}) where {id1, id2} = id1 == id2

struct ObjectIDMatcher{id} <: AbstractMatcher{id} end
ObjectIDMatcher(id::UInt64) = ObjectIDMatcher{id}()
ObjectIDMatcher(obj) = ObjectIDMatcher(objectid(obj))
Base.:(==)(::ObjectIDMatcher{id1}, ::ObjectIDMatcher{id2}) where {id1, id2} = id1 == id2

struct MatchAny{A} <: AbstractMatcher{A} end
MatchAny(matchers...) = MatchAny(tuple(matchers...))
function Base.:(==)(m1::MatchAny, a)
    return any(x -> x == a, getmatchers(m1))
end
function Base.:(==)(a, m1::MatchAny)
    return any(x -> x == a, getmatchers(m1))
end

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
