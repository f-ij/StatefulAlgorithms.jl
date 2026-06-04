"""
Type-stable location for a named loop child or state.

`Path` is a tuple of positional indexes through `(algos..., states...)` at each
loop-algorithm level. For example, `(2, 1)` means "second child of the current
loop, then first child of that nested loop".
"""
struct KeyLocation{Path} end

@inline KeyLocation(path::Tuple) = KeyLocation{path}()
@inline keypath(::KeyLocation{Path}) where {Path} = Path

"""Return an entity key, or `Symbol()` when the entity is not directly keyed."""
@inline _entity_key(::Any) = Symbol()
@inline _entity_key(entity::AbstractIdentifiableAlgo) = haskey(entity) ? getkey(entity) : Symbol()
@inline function _entity_key(::Type{Entity}) where {Entity<:AbstractIdentifiableAlgo}
    key = getkey(Entity)
    return isnothing(key) ? Symbol() : key
end

"""Return a nested loop algorithm carried by `entity`, or `nothing`."""
@inline _nested_loop(::Any) = nothing
@inline _nested_loop(loop::LA) where {LA<:AbstractLoopAlgorithm} = loop
@inline _nested_loop(::Type{LA}) where {LA<:AbstractLoopAlgorithm} = LA
@inline _nested_loop(entity::AbstractIdentifiableAlgo{F}) where {F} =
    F <: AbstractLoopAlgorithm ? getalgo(entity) : nothing
@inline _nested_loop(::Type{<:AbstractIdentifiableAlgo{F}}) where {F} =
    F <: AbstractLoopAlgorithm ? F : nothing

"""Return `(algos..., states...)` for following a `KeyLocation` path."""
@inline _key_children(loop::LA) where {LA<:AbstractLoopAlgorithm} = tuple(getalgos(loop)..., getstates(loop)...)
@inline _key_children(::Type{LA}) where {LA<:AbstractLoopAlgorithm} = tuple(algotypes(LA)..., statetypes(LA)...)

@inline _namespace_key(namespaces::Tuple, idx::Int) = namesymbol(getfield(namespaces, idx))
@inline _namespace_key(::Type{NS}, idx::Int) where {NS<:Tuple} = namesymbol(fieldtype(NS, idx))
@inline _namespace_key(::Nothing, idx::Int) = nothing

@inline _namespace_tuple(loop::Union{CompositeAlgorithm, Routine}) = getfield(loop, :namespaces)
@inline _namespace_tuple(::Type{<:Union{CompositeAlgorithm{FT,S,NS}, Routine{FT,S,NS}}}) where {FT,S,NS} = NS
@inline _namespace_tuple(loop::LoopAlgorithm) = _namespace_tuple(getplan(loop))
@inline _namespace_tuple(::Type{<:LoopAlgorithm{Plan}}) where {Plan} = _namespace_tuple(Plan)
@inline _namespace_tuple(loop::FinalizedAlgorithm) = _namespace_tuple(inneralgorithm(loop))
@inline _namespace_tuple(::Type{FA}) where {LA,FA<:FinalizedAlgorithm{LA}} = _namespace_tuple(LA)
@inline _namespace_tuple(::Any) = nothing
@inline _namespace_tuple(::Type) = nothing

"""Return the direct key for a loop child, preferring resolved namespaces."""
@inline function _child_key(loop, idx::Int, child)
    key = _namespace_key(_namespace_tuple(loop), idx)
    return isnothing(key) ? _entity_key(child) : key
end

function _append_keys!(names::Vector{Symbol}, loop)
    children = getalgos(loop)
    for idx in eachindex(children)
        child = children[idx]
        key = _child_key(loop, idx, child)
        key == Symbol() || push!(names, key)

        nested = _nested_loop(child)
        isnothing(nested) || _append_keys!(names, _key_source(nested))
    end

    for state in getstates(loop)
        key = _entity_key(state)
        key == Symbol() || push!(names, key)
    end
    return names
end

function _append_keys!(names::Vector{Symbol}, ::Type{LA}) where {LA<:AbstractLoopAlgorithm}
    child_types = algotypes(LA)
    for idx in eachindex(child_types)
        child_type = child_types[idx]
        key = _child_key(LA, idx, child_type)
        key == Symbol() || push!(names, key)

        nested = _nested_loop(child_type)
        isnothing(nested) || _append_keys!(names, _key_source(nested))
    end

    for state_type in statetypes(LA)
        key = _entity_key(state_type)
        key == Symbol() || push!(names, key)
    end
    return names
end

@inline _key_source(loop::FinalizedAlgorithm) = inneralgorithm(loop)
@inline _key_source(::Type{FA}) where {LA,FA<:FinalizedAlgorithm{LA}} = LA
@inline _key_source(loop) = loop

"""Return all named children and states visible from a loop algorithm tree."""
function Base.keys(loop::LA) where {LA<:AbstractLoopAlgorithm}
    return tuple(_append_keys!(Symbol[], _key_source(loop))...)
end

@generated function Base.keys(::Type{LA}) where {LA<:AbstractLoopAlgorithm}
    names = tuple(_append_keys!(Symbol[], _key_source(LA))...)
    return Expr(:tuple, (QuoteNode(name) for name in names)...)
end

function _findkey(loop, key::Symbol, prefix::Tuple)
    children = getalgos(loop)
    for idx in eachindex(children)
        child = children[idx]
        child_key = _child_key(loop, idx, child)
        child_key == key && child_key != Symbol() && return KeyLocation((prefix..., idx))

        nested = _nested_loop(child)
        if !isnothing(nested)
            location = _findkey(nested, key, (prefix..., idx))
            isnothing(location) || return location
        end
    end

    offset = length(children)
    for (idx, state) in pairs(getstates(loop))
        state_key = _entity_key(state)
        state_key == key && state_key != Symbol() && return KeyLocation((prefix..., offset + idx))
    end
    return nothing
end

function _findkey(::Type{LA}, key::Symbol, prefix::Tuple) where {LA<:AbstractLoopAlgorithm}
    child_types = algotypes(LA)
    for idx in eachindex(child_types)
        child_type = child_types[idx]
        child_key = _child_key(LA, idx, child_type)
        child_key == key && child_key != Symbol() && return KeyLocation((prefix..., idx))

        nested = _nested_loop(child_type)
        if !isnothing(nested)
            location = _findkey(nested, key, (prefix..., idx))
            isnothing(location) || return location
        end
    end

    offset = length(child_types)
    for (idx, state_type) in pairs(statetypes(LA))
        state_key = _entity_key(state_type)
        state_key == key && state_key != Symbol() && return KeyLocation((prefix..., offset + idx))
    end
    return nothing
end

"""Return the `KeyLocation` for `key`, or `nothing` if the key is not visible."""
@inline findkey(loop::LA, key::Symbol) where {LA<:AbstractLoopAlgorithm} = _findkey(_key_source(loop), key, ())
@inline findkey(::Type{LA}, key::Symbol) where {LA<:AbstractLoopAlgorithm} = _findkey(_key_source(LA), key, ())
@inline Base.haskey(loop::LA, key::Symbol) where {LA<:AbstractLoopAlgorithm} = !isnothing(findkey(loop, key))
@inline Base.haskey(::Type{LA}, key::Symbol) where {LA<:AbstractLoopAlgorithm} = !isnothing(findkey(LA, key))

function _getindex_keylocation(current, path::Tuple)
    child = _key_children(current)[first(path)]
    length(path) == 1 && return child

    nested = _nested_loop(child)
    isnothing(nested) && error("KeyLocation $(path) descends through non-LoopAlgorithm child $(child).")
    return _getindex_keylocation(nested, Base.tail(path))
end

@inline Base.getindex(loop::LA, location::KeyLocation) where {LA<:AbstractLoopAlgorithm} =
    _getindex_keylocation(loop, keypath(location))
