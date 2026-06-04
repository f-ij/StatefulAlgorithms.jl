@generated function static_findfirst_match(r::Type{SR}, ::Val{val}) where {SR <: SimpleRegistry{T} where T,val}
    ETypes = entrytypes(SR)
    fidx = findfirst(x -> match(x, val), ETypes)
    if isnothing(fidx)
        return :(nothing)
    end
    return :($fidx)
end
