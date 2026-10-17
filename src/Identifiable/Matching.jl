# An `IdentifiableAlgo` matches by its id (type parameter 2), on the instance and on the type.
match_by(sa::IdentifiableAlgo) = id(sa)
match_by(::Union{T,Type{T}}) where {T<:IdentifiableAlgo} = id(T)

id(sa::IdentifiableAlgo{F, Id}) where {F, Id} = Id
id(sat::Type{<:IdentifiableAlgo{F, Id}}) where {F, Id} = Id

setid(sa::SA, newid) where {SA<:IdentifiableAlgo} = setparameter(sa, 2, newid isa UUID ? SimpleId(newid) : newid)
