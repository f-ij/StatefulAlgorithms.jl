@inline getdata(sc::SubContext) = getfield(sc, :data)

"""
    withdata(sc, data)

Return an immutable `SubContext` rebuild with the same logical key and new
local data.
"""
@inline function withdata(sc::SubContext{Name}, data::D) where {Name,D<:NamedTuple}
    return SubContext{Name,D}(data)
end

@inline function newdata(sc::SubContext, data::NamedTuple)
    return @inline withdata(sc, data)
end

@inline Base.isempty(sc::SubContext) = isempty(getdata(sc))
@inline getdatatype(sct::Type{<:SubContext{Name,T}}) where {Name,T} = T
@inline Base.getkey(sc::SubContext) = getfield(sc, :name)
@inline Base.getkey(::Type{<:SubContext{Name}}) where {Name} = Name
@inline getdatatype(sc::SubContext) = getdatatype(typeof(sc))

@inline Base.pairs(sc::SubContext) = pairs(getdata(sc))
@inline function Base.getproperty(sc::SubContext, name::Symbol)
    if name === :name || name === :data
        return getfield(sc, name)
    end
    if !haskey(getdata(sc), name)
        error("Key $name not found in SubContext $(sc) \n with keys $(keys(getdata(sc)))")
    end
    getproperty(getdata(sc), name)
end

@inline function Base.merge(sc::SubContext{Name,T}, args::NamedTuple) where {Name,T}
    merged = merge(getdata(sc), args)
    return @inline withdata(sc, merged)
end

"""
Merge subcontext into a NamedTuple.
"""
@inline function Base.merge(args::NamedTuple, sc::SubContext{Name,T}) where {Name,T}
    return merge(args, getdata(sc))
end

@inline function Base.replace(sc::SubContext{Name,T}, args::NamedTuple = (;)) where {Name,T}
    return @inline withdata(sc, args)
    # Accessors path kept for comparison:
    # return @inline @set sc.data = args
end

@inline Base.keys(sct::Type{<:SubContext}) = fieldnames(getdatatype(sct))
@inline Base.keys(sc::SubContext) = propertynames(getdata(sc))

@inline Base.iterate(sc::SubContext, state = 1) = iterate(getdata(sc), state)
