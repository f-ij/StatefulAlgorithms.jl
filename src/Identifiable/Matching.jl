# An `IdentifiableAlgo` matches by its id (type parameter 2), on the instance and on the type.
# `@nospecialize`: a call on a handle whose type is known only at run time (the registry lookup key of every new
# `Unique` handle) compiles once; a typed call still infers and folds.
match_by(@nospecialize(sa::IdentifiableAlgo)) = id(sa)
match_by(::Union{T,Type{T}}) where {T<:IdentifiableAlgo} = id(T)

# The matcher value: from the `matcher` field when it carries data, else the type parameter.
id(@nospecialize(sa::IdentifiableAlgo{F, Id, VA, AlgoName, Key, Nothing})) where {F, Id, VA, AlgoName, Key} = Id
id(@nospecialize(sa::IdentifiableAlgo)) = getfield(sa, :matcher)
id(sat::Type{<:IdentifiableAlgo{F, Id}}) where {F, Id} = Id

setid(sa::SA, newid) where {SA<:IdentifiableAlgo} = setmatcher(sa, newid isa UUID ? SimpleId(newid) : newid)
