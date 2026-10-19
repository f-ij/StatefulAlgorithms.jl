@generated function static_findfirst_match(r::Type{SR}, ::Val{val}) where {SR <: SimpleRegistry{T} where T,val}
    # A loop, not `findfirst` with a closure: the closure captures `val` and compiles for every value.
    fidx = nothing
    for (i, E) in enumerate(getalgotypes(SR))
        if match(E, val)
            fidx = i
            break
        end
    end
    return :($fidx)
end
