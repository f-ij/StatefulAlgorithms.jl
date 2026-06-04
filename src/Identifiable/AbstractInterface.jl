### FALLBACKS ###
id(obj::Any) = nothing
hasid(::Any) = false
replacecontextkeys(a::Any, name_replacements) = a
setcontextkey(a::Any, newname) = a
algotype(f::Any) = typeof(f)

##########################################################
################ AbstractIdentifiableAlgo ################
##########################################################


abstract type AbstractIdentifiableAlgo{F, Id, VarAliases, AlgoName,ContextKey} <: ProcessAlgorithm end




staticmach_by(::Union{<:AbstractIdentifiableAlgo{F,Id},Type{<:AbstractIdentifiableAlgo{F,Id}}}) where {F,Id} = Id

@inline contextkey(sa::Union{AbstractIdentifiableAlgo{F, Id, Aliases, AlgoName, ContextKey}, Type{<:AbstractIdentifiableAlgo{F, Id, Aliases, AlgoName, ContextKey}}}) where {F, Id, Aliases, AlgoName, ContextKey} = ContextKey
@inline id(sa::Union{<:AbstractIdentifiableAlgo{F,Id},Type{<:AbstractIdentifiableAlgo{F,Id}}}) where {F,Id} = Id
@inline hasid(sa::AbstractIdentifiableAlgo) = !isnothing(id(sa))
@inline algotype(::Union{AbstractIdentifiableAlgo{F},Type{<:AbstractIdentifiableAlgo{F}}}) where {F} = F


@inline algoname(sa::AbstractIdentifiableAlgo{F,Id,Aliases,AlgoName}) where {F,Id,Aliases,AlgoName} = AlgoName == Symbol() ? nothing : AlgoName


@inline function Base.getkey(sat::Type{<:AbstractIdentifiableAlgo{F,Id,Aliases,AlgoName,ContextKey}}) where {F,Id,Aliases,AlgoName,ContextKey}
    ContextKey
end
# @inline function setkey(sa::AbstractIdentifiableAlgo, newkey)
#     error("setkey not implemented for type: $(typeof(sa)). This function should be implemented for any subtype of AbstractIdentifiableAlgo to allow for proper key management within registries and processes.")
# end

function mergereturn(sa::Union{<:AbstractIdentifiableAlgo{F,Id,Aliases,AlgoName,ContextKey}, Type{<:AbstractIdentifiableAlgo{F,Id,Aliases,AlgoName,ContextKey}}}, 
    args, 
    returnval) where {F,Id,Aliases,AlgoName,ContextKey}
    (; args..., (ContextKey => (; getproperty(returnval, ContextKey)..., returnval...)))
end

@inline varaliases(sa::Union{AbstractIdentifiableAlgo{F,Id,Aliases},Type{<:AbstractIdentifiableAlgo{F,Id,Aliases}}}) where {F,Id,Aliases} = Aliases

# """
# Update the keys in the Package's registry to match those in the provided registry, based on the algorithms contained in the Package. This is necessary to ensure that when the Package is used within a Process, it can correctly match its internal algorithms to those in the Process's registry for input/output mapping and overrides.
# """
# function update_keys(ca::AbstractIdentifiableAlgo, reg)
#     return reg[ca]
# end

########################################
############### Traits #################
########################################

@inline setid(sa::AbstractIdentifiableAlgo, newid) = error("Not implemented for type: $(typeof(sa))")
@inline getalgo(sa::AbstractIdentifiableAlgo{F}) where {F} = error("Not implemented for type: $(typeof(sa))")
@inline getalgos(sa::AbstractIdentifiableAlgo) = error("Not implemented for type: $(typeof(sa))")

@inline function hasautokey(sa::AbstractIdentifiableAlgo)
    key = getkey(sa)
    (!isnothing(key) && key != Symbol()) || return false
    startswith(string(key), "$(nameof(typeof(getalgo(sa))))_")
end
@inline function Base.haskey(sa::AbstractIdentifiableAlgo)
    key = getkey(sa)
    !isnothing(key) && key != Symbol()
end
@inline hasgivenkey(sa::AbstractIdentifiableAlgo) = haskey(sa) && !hasautokey(sa)

################################################
########## SETTING PROPERTIES/TRAITS ###########
################################################

setcontextkey(sa::AbstractIdentifiableAlgo, newname::Symbol) = error("Not implemented for type: $(typeof(sa))")
replacecontextkeys(a::AbstractIdentifiableAlgo, ::Any) = error("Not implemented for type: $(typeof(a))")
setvaraliases(sa::AbstractIdentifiableAlgo, newaliases) = error("Not implemented for type: $(typeof(sa))")
