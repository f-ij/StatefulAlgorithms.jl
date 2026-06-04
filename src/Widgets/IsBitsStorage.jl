const IsBitsStore = Dict{UUID, Any}()
const ConstructedPtrs = Set{UUID}()

"""
Is bits external storate for ProcessAlgorithms
    Can be useful to equip an algorithm with dynamic storage
"""
struct IsBitsPtr{T, id} end

function DelayedIsBitsPtr(::Type{T}) where T
    id = uuid4()
    IsBitsStore[id] = nothing
    push!(ConstructedPtrs, id)
    return IsBitsPtr{T, id}()
end

function IsBitsPtr(data::T) where T
    id = uuid4()
    IsBitsStore[id] = data
    push!(ConstructedPtrs, id)
    return IsBitsPtr{T, id}()
end

function Base.getindex(::IsBitsPtr{T, id}) where {T, id}
    return IsBitsStore[id]::T
end

function Base.getindex(::IsBitsPtr{T, id}, idx) where {T, id}
    @assert T <: AbstractArray || T<:Tuple "IsBitsPtr type T must be an AbstractArray to index into it"
    data = IsBitsStore[id]::T
    return data[idx]
end

function free!(ptr::IsBitsPtr{T, id}) where {T, id}
    delete!(IsBitsStore, id)
    return nothing
end

