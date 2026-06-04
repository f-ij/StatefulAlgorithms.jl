function setcontextkey(sa::IdentifiableAlgo{F}, newname::Symbol) where {F}
    IdentifiableAlgo{F, id(sa), varaliases(sa), algoname(sa), newname}(sa.func)
end

########################################
############### Traits #################
########################################
"""
The type with which this gets registered in the registry
"""
registry_entrytype(::Type{<:IdentifiableAlgo{T}}) where {T} = T

# match_id(sa::IdentifiableAlgo) = id(sa)
# match_id(::Union{T,Type{T}}) where {T<:IdentifiableAlgo} = id(T)

match_by(sa::IdentifiableAlgo) = id(sa)
match_by(::Union{T,Type{T}}) where {T<:IdentifiableAlgo} = id(T)

id(sa::IdentifiableAlgo{F, Id}) where {F, Id} = Id
id(sat::Type{<:IdentifiableAlgo{F, Id}}) where {F, Id} = Id

setid(sa::SA, newid) where {SA<:IdentifiableAlgo} = setparameter(sa, 2, newid isa UUID ? SimpleId(newid) : newid)

algoname(sa::IdentifiableAlgo{F, Id, Aliases, AlgoName}) where {F, Id, Aliases, AlgoName} = AlgoName == Symbol() ? nothing : AlgoName

varaliases(sa::Union{IdentifiableAlgo{F, Id, Aliases}, Type{<:IdentifiableAlgo{F, Id, Aliases}}}) where {F, Id, Aliases} = Aliases

getvaraliases(sa::Union{IdentifiableAlgo{F, Id, Aliases}, Type{<:IdentifiableAlgo{F, Id, Aliases}}}) where {F, Id, Aliases} = Aliases
# setvaraliases(sa::IdentifiableAlgo{F, Id, Aliases}, newaliases) where {F, Id, Aliases} = setparameter(sa, 3, newaliases)

algotype(::Union{IdentifiableAlgo{F}, Type{<:IdentifiableAlgo{F}}}) where {F} = F


@inline getalgo(sa::IdentifiableAlgo{F}) where {F} = sa.func
@inline getalgos(sa::IdentifiableAlgo) = tuple(sa.func)
@inline _profile_step_algo(sa::AbstractIdentifiableAlgo) = getalgo(sa)
@inline _profile_step_context(sa::AbstractIdentifiableAlgo, context) = view(context, sa)

@inline Base.getkey(sa::IdentifiableAlgo) = getkey(typeof(sa))
@inline function Base.getkey(sat::Type{<:IdentifiableAlgo{F, Id, Aliases, AlgoName, ScopeName}}) where {F, Id, Aliases, AlgoName, ScopeName}
    ScopeName
end
# @inline setkey(sa::IdentifiableAlgo, newkey) = setparameter(sa, 6, newkey)

function mergereturn(sa::IdentifiableAlgo{F, Id, Aliases, AlgoName, ScopeName}, args, returnval) where {F, Id, Aliases, AlgoName, ScopeName}
    (;args..., (ScopeName => (;getproperty(returnval, ScopeName)..., returnval...)))
end


################################################
########## SETTING PROPERTIES/TRAITS ###########
################################################

"""
For bulk replacement of names
"""
function replacecontextkeys(a::IdentifiableAlgo{F, Id, Aliases, AlgoName, OldKey}, key_replacement::Pair) where {F, Id, Aliases, AlgoName, OldKey}
    if OldKey == key_replacement[1]
        return setcontextkey(a, key_replacement[2])
    end
    return a
end

function replacecontextkeys(a::IdentifiableAlgo{F, Id, Aliases, AlgoName, OldKey}, key_replacements::AbstractArray{<:Pair}) where {F, Id, Aliases, AlgoName, OldKey}
    for nr in key_replacements
        if OldKey == nr[1]
            return setcontextkey(a, nr[2])
        end
    end
    return a
end

function setvaraliases(sa::IdentifiableAlgo{F, Id, Aliases}, newaliases) where {F, Id, Aliases}
    setparameter(sa, 3, newaliases)
end

####################################
############ SHOWING ###############
####################################
IdentifiableAlgo_label(sa::IdentifiableAlgo) = string((isnothing(algoname(sa)) ? summary(getalgo(sa)) : algoname(sa)),"@",getkey(sa))

function Base.show(io::IO, sa::IdentifiableAlgo)
    algo_repr = sprint(show, getalgo(sa))
    print(io, IdentifiableAlgo_label(sa), ": ", algo_repr)
    @static if debug_mode()
        print(io, " [match_by=", match_by(sa), "]")
    end
end
