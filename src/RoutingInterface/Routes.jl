################################################
##################  ROUTES  ####################
################################################

"""Return the unresolved endpoint reference stored on a route."""
getfrom(r::Route) = getfield(r, :from)

"""Return the unresolved target reference stored on a route."""
getto(r::Route) = getfield(r, :to)

"""Return source variable names carried by a route."""
getvarnames(::Union{Route{Fmatch, Tmatch, FT, RFT, varnames}, Type{<:Route{Fmatch, Tmatch, FT, RFT, varnames}}}) where {Fmatch, Tmatch, FT, RFT, varnames} = varnames

"""Return local variable aliases carried by a route."""
getaliases(::Union{Route{Fmatch, Tmatch, FT, RFT, varnames, aliases}, Type{<:Route{Fmatch, Tmatch, FT, RFT, varnames, aliases}}}) where {Fmatch, Tmatch, FT, RFT, varnames, aliases} = aliases

"""Return the transform function carried by a route."""
gettransform(::Union{Route{Fmatch, Tmatch, FT}, Type{<:Route{Fmatch, Tmatch, FT}}}) where {Fmatch, Tmatch, FT} = FT

"""Return the reverse transform function carried by a route."""
getreverse_transform(::Union{Route{Fmatch, Tmatch, FT, RFT}, Type{<:Route{Fmatch, Tmatch, FT, RFT}}}) where {Fmatch, Tmatch, FT, RFT} = RFT

"""Return the route origin matcher identity or resolved origin name."""
from_match_by(::Union{Route{Fmatch}, Type{<:Route{Fmatch}}}) where {Fmatch} = Fmatch

"""Return the route target matcher identity or resolved target name."""
to_match_by(::Union{Route{Fmatch, Tmatch}, Type{<:Route{Fmatch, Tmatch}}}) where {Fmatch, Tmatch} = Tmatch

"""Return whether a route has already been resolved to context-name symbols."""
isresolved(r::Union{Route{Fmatch, Tmatch}, Type{<:Route{Fmatch, Tmatch}}}) where {Fmatch, Tmatch} =
    Fmatch isa Symbol && Tmatch isa Symbol

"""Return the source context name for a resolved route."""
get_fromname(r::Union{Route{Fmatch}, Type{<:Route{Fmatch}}}) where {Fmatch} = Fmatch

"""Return the route aliases expected by generated view code."""
@inline localnames(r::Union{Route{Fmatch, Tmatch, FT, RFT, varnames, aliases}, Type{<:Route{Fmatch, Tmatch, FT, RFT, varnames, aliases}}}) where {Fmatch, Tmatch, FT, RFT, varnames, aliases} = aliases

"""Return the route source variable names expected by generated view code."""
@inline subvarcontextnames(r::Union{Route{Fmatch, Tmatch, FT, RFT, varnames}, Type{<:Route{Fmatch, Tmatch, FT, RFT, varnames}}}) where {Fmatch, Tmatch, FT, RFT, varnames} = varnames

Base.keys(r::Union{Route, Type{<:Route}}) = getvarnames(r)
Base.values(r::Union{Route, Type{<:Route}}) = getaliases(r)
