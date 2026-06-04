@inline @generated function separated_keys(reg::Union{NSR, Type{<:NSR}}) where NSR<:NameSpaceRegistry
    type_entries = typeentry_types(NSR)
    allkeys = keys.(type_entries)
    return :($allkeys)
end

@inline @generated function Base.keys(reg::Union{NSR, Type{NSR}}) where NSR<:NameSpaceRegistry
    allkeys = separated_keys(NSR)
    allkeys_flat = tuple(Iterators.Flatten(allkeys)...)
    return :($allkeys_flat)
end

@inline findkey(reg::Union{NSR, Type{NSR}}, key::Symbol) where NSR<:NameSpaceRegistry = findkey(reg, Val(key))
@inline @generated function findkey(reg::Union{NSR, Type{NSR}}, ::Val{K}) where {NSR<:NameSpaceRegistry, K}
    _separated_keys = separated_keys(NSR)
    firstkeyidx = findfirst(ks -> K in ks, _separated_keys)
    if isnothing(firstkeyidx)
        return nothing, nothing
    else
        secondkeyidx = findfirst(==(K), _separated_keys[firstkeyidx])
        return (firstkeyidx, secondkeyidx)
    end
end

@inline Base.haskey(reg::Union{NSR, Type{NSR}}, key::Symbol) where NSR<:NameSpaceRegistry = haskey(NSR, Val(key))
@inline @generated function Base.haskey(reg::Union{NSR, Type{NSR}}, key::Val{K}) where {NSR<:NameSpaceRegistry, K}
    keyloc = findkey(NSR, K)
    if isnothing(keyloc[1])
        return false
    else
        return true
    end
end

Base.@constprop :aggressive @inline function Base.getproperty(reg::NameSpaceRegistry, key::Symbol)
    keyloc = findkey(reg, Val(key))
    if isnothing(keyloc[1])
        error("Key $key not found in registry $reg with keys $(keys(reg))")
    else
        return getindex(getindex(reg, keyloc[1]), keyloc[2])
    end
end