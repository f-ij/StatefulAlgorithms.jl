@generated function _find_typeidx(reg::Type{NSR}, typ::Type{T}) where {NSR <: NameSpaceRegistry, T}
    it = entrytypes_iterator(NSR)
    index = findfirst(t -> T <: t, it)
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        idx = $index
        return idx
    end
end

@inline @generated function static_findfirst_match(rte::RegistryTypeEntry{T,S}, v::Val{value}) where {T,S,value}
    idx = findfirst(x -> match(value, x), entry_types(rte))
    return :($idx)
end
