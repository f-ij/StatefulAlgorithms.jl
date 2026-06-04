# setvalue(se::ScopedValueEntry{T,V}, newval) where {T,V} = ScopedValueEntry{typeof(newval), newval}(se.multiplier)
# setmultiplier(se::ScopedValueEntry{T,V}, newmult) where {T,V} = ScopedValueEntry{T,V}(newmult)

# getvalue(se::ScopedValueEntry{T,V}) where {T,V} = V
# getvalue(set::Type{ScopedValueEntry{T,V}}) where {T,V} = V

# isdefault(rte::ScopedValueEntry{T}) where {T} = isdefault(T)
# isdefault(rte::Type{<:ScopedValueEntry{T}}) where {T} = isdefault(T)

# """
# Get the name of the scoped value entry
# """
# getkey(se::ScopedValueEntry{T,V}) where {T,V} = getkey(getvalue(se))


# ### CHANGING ###
# """
# Change the name of the scoped value entry and return a new scoped value entry
# """
# changename(se::ScopedValueEntry{T,V}, newname::Symbol) where {T,V} = setvalue(se, changename(getvalue(se), newname))
# setid(se::SE, newid) where {SE<:ScopedValueEntry} = setvalue(se, setid(getvalue(se), newid))


# function match(se::Union{ScopedValueEntry{T,V}, Type{ScopedValueEntry{T,V}}}, val) where {T,V}
#     if isdefault(V) # Default values match either type, or another default value by instance
#         if val isa Type
#             return T <: val
#         elseif isdefault(val)
#             return unwrap_container(V) === unwrap_container(val)
#         else
#             return false
#         end
#     end

#     isinstance(V, val)
# end

# function match(se1::Union{ScopedValueEntry{T1,V1}, Type{ScopedValueEntry{T1,V1}}}, 
#                se2::Union{ScopedValueEntry{T2,V2}, Type{ScopedValueEntry{T2,V2}}}) where {T1,V1,T2,V2}
#     if isdefault(se1) # Default values match either type, or another default value by instance
#         if se2 isa Type
#             return T1 <: se2
#         elseif isdefault(se2)
#             return isinstance(unwrap_container(se1), unwrap_container(se2))
#         else
#             return false
#         end
#     end

#     isinstance(unwrap_container(se1), unwrap_container(se2))
# end

# match(val, te::Union{ScopedValueEntry,Type{<:ScopedValueEntry}}) = match(te, val)

# match(::Union{Nothing, Type{<:Nothing}}, ::Any) = false
# match(::Any, ::Union{Nothing, Type{<:Nothing}}) = false
# match(::Union{Nothing, Type{<:Nothing}}, te::Union{ScopedValueEntry,Type{<:ScopedValueEntry}}) = false

# multiplier(ve::ScopedValueEntry) = ve.multiplier

# value(ve::ScopedValueEntry) = getvalue(ve)
# value(a::Any) = a
# value(::Nothing) = nothing

# scale_multiplier(n::Nothing, factor::Number) = nothing
# scale_multiplier(ve::ScopedValueEntry{T}, factor::Number) where T = setmultiplier(ve, ve.multiplier * factor)
# add_multiplier(ve::ScopedValueEntry{T}, num::Number) where T = setmultiplier(ve, ve.multiplier + num)

# thincontainer(::Type{<:ScopedValueEntry}) = true
# _contained_type(::Type{<:ScopedValueEntry{T,V}}) where {T,V} = T
# _unwrap_container(se::ScopedValueEntry{T,V}) where {T,V} = getvalue(se)

