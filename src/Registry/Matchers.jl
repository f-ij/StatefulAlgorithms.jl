# export All
# struct All{T} end
# All(::Type{T}) where {T} = All{T}()
# gettype(::All{T}) where {T} = T

# function static_get(reg:::AbstractRegistry, obj::All{T}) where {T}
#     type_entries = get_type_entries(reg, T)
#     return tuple(type_entries...)
# end