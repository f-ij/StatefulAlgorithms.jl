##########################################
########## VarLocation getters ###########
##########################################

"""Return the read transform carried by a `VarLocation` (`nothing` when the value is read as stored)."""
@inline getfunc(vl::Union{VarLocation{T, subcontextname, originalname, func}, Type{<:VarLocation{T, subcontextname, originalname, func}}}) where {T, subcontextname, originalname, func} = func

"""Return the writeback transform carried by a `VarLocation`."""
@inline getreversefunc(vl::Union{VarLocation{T, subcontextname, originalname, func, reversefunc}, Type{<:VarLocation{T, subcontextname, originalname, func, reversefunc}}}) where {T, subcontextname, originalname, func, reversefunc} = reversefunc

"""Return the name of the subcontext (namespace or runtime partition) a `VarLocation` is stored in."""
@inline get_subcontextname(vl::Union{VarLocation{T, SCN, ON}, Type{<:VarLocation{T, SCN, ON}}}) where {T, SCN, ON} = SCN

"""Return the field (or tuple of fields) a `VarLocation` names in its subcontext."""
@inline location_fieldname(vl::Union{VarLocation{T, SCN, ON}, Type{<:VarLocation{T, SCN, ON}}}) where {T, SCN, ON} = ON
