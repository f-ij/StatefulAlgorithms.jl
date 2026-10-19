@generated function _find_typeidx(reg::Type{NSR}, typ::Type{T}) where {NSR <: NameSpaceRegistry, T}
    # A loop over the entry types, not `findfirst` with a closure: the closure captures `T` and compiles for every type.
    index = nothing
    entries = NSR.parameters[1].parameters
    for i in 1:length(entries)
        if T <: getentrytype(entries[i])
            index = i
            break
        end
    end
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        idx = $index
        return idx
    end
end

@inline @generated function static_findfirst_match(rte::RegistryTypeEntry{T,S}, v::Val{value}) where {T,S,value}
    # A loop, not `findfirst` with a closure: the closure captures `value` and compiles for every value.
    idx = nothing
    algotypes = getalgotypes(rte)
    for i in 1:length(algotypes)
        if match(value, algotypes[i])
            idx = i
            break
        end
    end
    return :($idx)
end
