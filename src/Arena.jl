export Arena, AVec, AArray, resizeblock!, growblock!, add_to_size!, getblock, 
    AVecAlloc, AArrayAlloc

#Ref
export ARef

"""
Values of block i are stored in data[blocks[i]:blocks[i+1]-1]
Number of elements in block i is blocks[i+1] - blocks[i]

"""
const min_size = 8
const growth_factor = 2
const max_growth = 1024

# Calculate aligned position for a type
function aligned_position(pos::Int, ::Type{T}) where T
    alignment = Base.datatype_alignment(T)
    return (pos + alignment - 1) & ~(alignment - 1)
end

abstract type Allocator end


struct Arena <: Allocator
    data::Vector{UInt8} # Data of the arena is allocated per 8 bits
    blocks::Vector{Int} # Indexes where the blocks start
    refs::Vector{Any}
    block_allocs::Vector{Int} # Allocated capacity for each block (in elements)
end

blockstart(a::Arena, block::Int) = a.blocks[block]
blockend(a::Arena, block::Int) = a.blocks[block+1]-1
blocklength(a::Arena, block::Int) = a.blocks[block+1] - a.blocks[block]
number_of_type(a::Arena, block::Int) = blocklength(a, block) ÷ sizeof(eltype(a.refs[block]))
Base.length(a::Arena) = length(a.data)

function Arena()
    return Arena(Vector{UInt8}(), [1], Any[], Int[])
end

function Base.resize!(a::Arena, newsize::Int)
    resize!(a.data, newsize)
end

function addblock!(a::Arena, type, amount)
    # Align the start position for this type
    start_pos = aligned_position(length(a.data) + 1, type)
    padding = start_pos - length(a.data) - 1
    bytes = sizeof(type) * amount
    resize!(a.data, start_pos - 1 + bytes)
    return start_pos, padding
end

"""
Resize block with index "block" to new_block_size.
new_block_size is given in multiples of the amount of bytes of the datatype
"""
function resizeblock!(a::Arena, block::Int, number_of_type::Int)
    ref = a.refs[block]
    bytesize = sizeof(eltype(ref))
    new_block_size = number_of_type * bytesize
    old_block_size = blocklength(a, block)
    offset = new_block_size - old_block_size

    oldsize = length(a.data)
    newsize = oldsize + offset
    offset == 0 && return

    if offset > 0
        resize!(a.data, newsize)
        tail_start = blockend(a, block) + 1
        tail_len = oldsize - tail_start + 1
        if tail_len > 0
            src = pointer(a.data, tail_start)
            dest = pointer(a.data, tail_start + offset)
            unsafe_copyto!(dest, src, tail_len)
        end
    else
        tail_start = blockend(a, block) + 1
        tail_len = oldsize - tail_start + 1
        if tail_len > 0
            src = pointer(a.data, tail_start)
            dest = pointer(a.data, tail_start + offset)
            unsafe_copyto!(dest, src, tail_len)
        end
        resize!(a.data, newsize)
    end

    # Update block starts for all blocks after the resized one
    for i in block+1:length(a.blocks)
        a.blocks[i] += offset
    end

    # Update positions for refs after the resized block
    for i in block+1:length(a.refs)
        ref = a.refs[i]
        if hasproperty(ref, :pos)
            ref.pos += offset
        end
    end

    # Update the allocated capacity for this block
    a.block_allocs[block] = number_of_type

    # Update alloc field in the ref if it has one
    if hasproperty(ref, :alloc)
        ref.alloc = number_of_type
    end

    # Rebuild all pointers since resize! can reallocate
    for i in 1:length(a.refs)
        ref = a.refs[i]
        if hasproperty(ref, :ptr)
            ref.ptr = pointer(a.data, ref.pos)
        end
    end
end

function growblock!(a::Arena, block::Int)
    current_alloc = a.block_allocs[block]
    
    # Grow by factor, but ensure we grow by at least 1 element
    growth = max(current_alloc * (growth_factor - 1), 1)
    # Cap individual growth increments, but allow total size to exceed max_growth
    growth = min(growth, max_growth)
    new_block_size = current_alloc + growth
    
    @inline resizeblock!(a, block, new_block_size)
end

function add_to_size!(a::Arena, datatype, newsize::Int)
    oldlength = length(a.data)
    _sizeof = sizeof(datatype)
    resize!(a.data, oldlength + newsize * _sizeof)
end

@inline function Base.size(a::Arena)
    return size(a.data)
end

# Generic arena array that works with multidimensional arrays
# AVec is a special case for 1D arrays
mutable struct AArray{T, N, BoundsCheck} <: AbstractArray{T, N}
    arena::Arena
    pos::Int
    ptr::Ptr{T}
    dims::NTuple{N, Int}  # Current dimensions
    alloc::Int  # Total allocated elements
end

# Type alias for 1D arena vectors
const AVec{T, BC} = AArray{T, 1, BC}

function AVecZeros(type, a::Arena, len; boundscheck = true)
    alloc_size = max(len, min_size)
    start_pos, padding = addblock!(a, type, alloc_size)
    push!(a.blocks, length(a.data) + 1)
    push!(a.block_allocs, alloc_size)
    ptr = pointer(a.data, start_pos)
    av = AArray{type, 1, boundscheck}(a, start_pos, ptr, (len,), alloc_size)
    push!(a.refs, av)
    # Zero initialize
    for i in 1:len
        unsafe_store!(ptr, zero(type), i)
    end
    return av
end

function AVecAlloc(type, a::Arena, len; boundscheck = true)
    alloc_size = max(len, min_size)
    start_pos, padding = addblock!(a, type, alloc_size)
    push!(a.blocks, length(a.data) + 1)
    push!(a.block_allocs, alloc_size)
    ptr = pointer(a.data, start_pos)
    av = AArray{type, 1, boundscheck}(a, start_pos, ptr, (0,), alloc_size)
    push!(a.refs, av)
    return av
end

function AVecInit(a, initvalues::AbstractVector; boundscheck = true)
    av = AVecAlloc(eltype(initvalues), a, length(initvalues) + 8)
    for val in initvalues
        push!(av, val)
    end
    return av
end

function AArrayAlloc(type, a::Arena, dims::NTuple{N, Int}; boundscheck = true) where N
    total_elements = prod(dims)
    alloc_size = max(total_elements, min_size)
    start_pos, padding = addblock!(a, type, alloc_size)
    push!(a.blocks, length(a.data) + 1)
    push!(a.block_allocs, alloc_size)
    ptr = pointer(a.data, start_pos)
    aa = AArray{type, N, boundscheck}(a, start_pos, ptr, dims, alloc_size)
    push!(a.refs, aa)
    return aa
end

function Base.getindex(a::AArray{T, 1, BC}, i::Int) where {T, BC}
    if BC
        @assert 1 <= i <= a.dims[1]
    end
    unsafe_load(a.ptr, i)
end

function Base.getindex(a::AArray{T, N, BC}, I::Vararg{Int, N}) where {T, N, BC}
    if BC
        @assert all(1 .<= I .<= a.dims)
    end
    # Calculate linear index
    idx = LinearIndices(a.dims)[I...]
    unsafe_load(a.ptr, idx)
end

function Base.setindex!(a::AArray{T, 1, BC}, val, i::Int) where {T, BC}
    if BC
        @assert 1 <= i <= a.dims[1]
    end
    unsafe_store!(a.ptr, val, i)
end

function Base.setindex!(a::AArray{T, N, BC}, val, I::Vararg{Int, N}) where {T, N, BC}
    if BC
        @assert all(1 .<= I .<= a.dims)
    end
    # Calculate linear index
    idx = LinearIndices(a.dims)[I...]
    unsafe_store!(a.ptr, val, idx)
end

@inline Base.length(a::AArray) = prod(a.dims)
@inline Base.size(a::AArray) = a.dims
@inline Base.size(a::AArray, d::Int) = a.dims[d]
@inline Base.eltype(a::AArray{T}) where T = T
Base.IteratorSize(::Type{<:AArray}) = Base.HasLength()
Base.IteratorEltype(::Type{<:AArray}) = Base.HasEltype()
Base.iterate(a::AArray, i::Int=1) = i > length(a) ? nothing : (a.ptr[i], i+1)
getblock(a::AArray) = findfirst(x -> x === a, a.arena.refs)

function Base.sizehint!(a::AArray{T, 1, BC}, newsize::Int) where {T, BC}
    if newsize > a.alloc
        block = getblock(a)
        resizeblock!(a.arena, block, newsize)
    end
end

@inline function Base.push!(a::AArray{T, 1, BC}, val::T) where {T, BC}
    if length(a) == a.alloc
        block = getblock(a)
        growblock!(a.arena, block)
    end

    new_len = a.dims[1] + 1
    a.dims = (new_len,)
    @inline unsafe_store!(a.ptr, val, new_len)
end

function Base.append!(a::AArray{T, 1, BC}, vals::AbstractVector{T}) where {T, BC}
    sizehint!(a, length(a) + length(vals))
    for val in vals
        push!(a, val)
    end
end

mutable struct ARef{T} <: Ref{T}
    ptr::Ptr{T}
    pos::Int
end

function Base.getindex(a::ARef{T}) where T
    unsafe_load(a.ptr)
end

function Base.setindex!(a::ARef{T}, val) where T
    unsafe_store!(a.ptr, val)
end

function Base.length(a::ARef)
    1
end

Base.size(a::ARef) = tuple()

function ARef(arena, val::T) where T
    oldlen = length(arena.data)
    add_to_size!(arena, T, 1)
    ptr = pointer(arena.data, oldlen + 1)
    push!(arena.blocks, oldlen + 2)
    unsafe_store!(ptr, val)
    ref = ARef(ptr, oldlen + 1)
    push!(arena.refs, ref)
    return ref
end
