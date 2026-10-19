
"""
Set an explicit name for an algorithm
"""
@inline function IdentifiableAlgo(f::F, contextkey::Symbol, id = nothing; customname = Symbol(), aliases...) where F
    if f isa AbstractIdentifiableAlgo # Don't wrap a IdentifiableAlgo again, just setid
        # return IdentifiableAlgo(getalgo(f), contextkey, id(f); aliases...)
        if !isnothing(id) && !isnothing(StatefulAlgorithms.id(f))
            error("Trying to wrap an IdentifiableAlgo with a new id")
        end
        return setcontextkey(f, contextkey)
    end

    if isnothing(id) # Not unique so auto matching
        id = match_by(f) # Either match by f, or get the matching behavior of f if set
        # if 
    elseif id isa UUID
        id = SimpleId(id)
    end
    f = instantiate(f) # Don't wrap a type
    aliases = VarAliases(;aliases...)

    # An id that is all type-level (the usual case) keeps the typed construction; one carrying data goes untyped.
    static_id(id) === id || return identifiable_with_id(f, id, aliases, customname, contextkey)
    IdentifiableAlgo{typeof(f), id, aliases, customname, contextkey}(f)::IdentifiableAlgo{typeof(f), id, aliases, customname, contextkey}
end

IdentifiableAlgo(f::F; key = Symbol(), id = nothing, customname = Symbol(), aliases...) where F = @inline IdentifiableAlgo(f, key, id; customname, aliases...)

# The same as the method above for an already identifiable value with no keywords (it only resets the key), without
# compiling the keyword path for every handle type, e.g. every `Unique` handle passed to a constructor.
Base.@nospecializeinfer IdentifiableAlgo(@nospecialize(f::AbstractIdentifiableAlgo)) = setcontextkey(f, Symbol())

"""
Scoped Algorithms don't wrap other IdentifiableAlgos
    We just change the name of the algorithm
"""
IdentifiableAlgo(na::IdentifiableAlgo, name::Symbol) = setcontextkey(na, name)

function Autokey(f::F, i::Int, id = nothing; customname = Symbol(), aliases...) where F
    f = instantiate(f)
    TName = autokey_basename(f)
    key = @inline static_symbol(TName,(:_), i)
    @inline IdentifiableAlgo(f, key, id; customname, aliases...)
end

function Autokey(f::IA, i::Int; customname = Symbol(), aliases...) where IA <: IdentifiableAlgo
    if getkey(f) != Symbol() # If it already has a key, don't change it
        return f
    end
    TName = autokey_basename(getalgo(f))
    key = @inline static_symbol(TName,(:_), i)
    setcontextkey(f, key)
end


## USER WRAPPERS ##

function Identified(f::F; customname = Symbol(), aliases...) where F
    if f isa IdentifiableAlgo && !isbits(f)
        wrapped = f.func
        @assert objectid(wrapped) == id(f) "Trying to identify an already identifiable algorithm with a different id"
        # TODO: Add aliases/customname
        return f
    elseif f isa AbstractIdentifiableAlgo || f isa Type
        return f 
    end

    # Otherwise a plain mutable value, so we id it by objectid
    IdentifiableAlgo{F, objectid(f), VarAliases(;aliases...), customname, Symbol()}(f)
end

"""
    Unique(f; customname, aliases...)

A handle of `f` with an identity of its own: two `Unique(f)` are two algorithms, each with its own state. Its matcher
is `UniquePlanId{uuid}(uuid)` with a fresh uuid, so the handle is a key known from its type (`context[handle]`). A
constructor strips the uuid from the type (`strip_unique`) and the plan numbers its handles (`number_unique_ids`), so
plans built from new `Unique`s have the same types.
"""
function Unique(f; customname = Symbol(), aliases...)
    f = instantiate(f)
    if !isbits(f)
        f = deepcopy(f) # Mutable types match by identity
    end
    identifiable_with_id(f, UniquePlanId(uuid4()), VarAliases(;aliases...), customname, Symbol())
end
