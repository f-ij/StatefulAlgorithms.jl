
"""
Thin container that stores a non-isbits value in a dynamic store.
"""
struct DynamicStore{id,T}
end

getid(d::Union{Type{<:DynamicStore{id,T}}, DynamicStore{id,T}}) where {id,T} = id

const DYNAMIC_STORE = Dict{UInt64, WeakRef}()
const DYNAMIC_REVERSE = WeakKeyDict{Any, UInt64}()
const _dynamic_counter = Ref{UInt64}(0)

function DynamicStore(x::T, id = (_dynamic_counter[] += 1)) where {T}
    DYNAMIC_STORE[id] = WeakRef(x)
    DYNAMIC_REVERSE[x] = id
    if !isbitstype(T)
        finalizer(x) do _
            delete!(DYNAMIC_STORE, id)
            delete!(DYNAMIC_REVERSE, x)
        end
    end
    return DynamicStore{id, T}()
end

function getvalue(d::DynamicStore)
    wref = get(DYNAMIC_STORE, getid(d), nothing)
    if wref === nothing || wref.value === nothing
        error("DynamicStore value not found in store for id $(getid(d))")
    end
    return wref.value
end

function release!(d::DynamicStore)
    wref = get(DYNAMIC_STORE, getid(d), nothing)
    if wref !== nothing
        x = wref.value
        if x !== nothing
            delete!(DYNAMIC_REVERSE, x)
        end
    end
    delete!(DYNAMIC_STORE, getid(d))
    return nothing
end

function getdynamicstore_id(x)
    return get(DYNAMIC_REVERSE, x, nothing)
end

#####
# Can be set later during processing
#####
function DelayedStore(x::Type{T} = Any) where {T}
    id = (_dynamic_counter[] += 1)
    DYNAMIC_STORE[id] = WeakRef(nothing)
    return DynamicStore{id, T}()
end

function setreference(d::DynamicStore{id,T}, x::DT) where {id,T, DT <: T}
    DYNAMIC_STORE[id] = WeakRef(x)
    DYNAMIC_REVERSE[x] = id
    if !isbitstype(T)
        finalizer(x) do _
            delete!(DYNAMIC_STORE, id)
            delete!(DYNAMIC_REVERSE, x)
        end
    end
    return nothing
end

## THINCONTAINER
thincontainer(::Type{<:DynamicStore}) = true
function (ds::DynamicStore{id,T})(newobj::O) where {id,T,O<:T} # Composition
    release!(ds)
    return DynamicStore(newobj, id)
end
_contained_type(::Type{<:DynamicStore{id, T}}) where {id, T} = typeof(DYNAMIC_STORE[id].value)
_unwrap_container(d::DynamicStore) = getvalue(d)

