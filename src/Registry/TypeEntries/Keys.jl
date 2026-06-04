@inline @generated function Base.keys(entry::Union{RTE, Type{<:RTE}}) where RTE<:RegistryTypeEntry
    _entrytypes = getentries(RTE)
    keys = getkey.(_entrytypes)
    return :($keys)
end

@inline Base.haskey(entry::RegistryTypeEntry, key::Symbol) = haskey(entry, Val(key))
@inline @generated function Base.haskey(entry::RTE, key::Val{K}) where {RTE<:RegistryTypeEntry, K}
    isin = key in keys(RTE)
    return :($isin)
end

@inline findkey(entry::RegistryTypeEntry, key::Symbol) = findkey(entry, Val(key))
@inline @generated function findkey(entry::RTE, ::Val{K}) where {RTE<:RegistryTypeEntry, K}
    _keys = keys(RTE)
    keyidx = findfirst(==(K), _keys)
    if isnothing(keyidx)
        return nothing
    else
        return :($keyidx)
    end
end