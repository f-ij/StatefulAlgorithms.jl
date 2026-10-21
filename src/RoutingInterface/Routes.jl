################################################
##################  ROUTES  ####################
################################################

"""Return the unresolved source-namespace reference stored on a route."""
get_source_ref(r::Route) = getfield(r, :source_ref)

"""Return the unresolved target-namespace reference stored on a route."""
get_target_ref(r::Route) = getfield(r, :target_ref)

"""Return the source field names carried by a route."""
source_fieldnames(::Union{Route{Smatch, Tmatch, FT, RFT, varnames}, Type{<:Route{Smatch, Tmatch, FT, RFT, varnames}}}) where {Smatch, Tmatch, FT, RFT, varnames} = varnames

"""Return the target field names (aliases) carried by a route."""
getaliases(::Union{Route{Smatch, Tmatch, FT, RFT, varnames, aliases}, Type{<:Route{Smatch, Tmatch, FT, RFT, varnames, aliases}}}) where {Smatch, Tmatch, FT, RFT, varnames, aliases} = aliases

"""Return the transform function carried by a route."""
gettransform(::Union{Route{Smatch, Tmatch, FT}, Type{<:Route{Smatch, Tmatch, FT}}}) where {Smatch, Tmatch, FT} = FT

"""Return the reverse transform function carried by a route."""
getreverse_transform(::Union{Route{Smatch, Tmatch, FT, RFT}, Type{<:Route{Smatch, Tmatch, FT, RFT}}}) where {Smatch, Tmatch, FT, RFT} = RFT

"""Return the route source-namespace matcher identity, or the resolved source namespace."""
source_match_by(::Union{Route{Smatch}, Type{<:Route{Smatch}}}) where {Smatch} = Smatch

"""Return the route target-namespace matcher identity, or the resolved target namespace."""
target_match_by(::Union{Route{Smatch, Tmatch}, Type{<:Route{Smatch, Tmatch}}}) where {Smatch, Tmatch} = Tmatch

"""Return whether a route has already been resolved to context-name symbols."""
isresolved(r::Union{Route{Smatch, Tmatch}, Type{<:Route{Smatch, Tmatch}}}) where {Smatch, Tmatch} =
    Smatch isa Symbol && Tmatch isa Symbol

"""Return the source namespace of a resolved route."""
source_namespace(r::Union{Route{Smatch}, Type{<:Route{Smatch}}}) where {Smatch} = Smatch

Base.keys(r::Union{Route, Type{<:Route}}) = source_fieldnames(r)
Base.values(r::Union{Route, Type{<:Route}}) = getaliases(r)
