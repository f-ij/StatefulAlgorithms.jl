using UUIDs

abstract type AbstractVarAlias end

"""
Used as a mapping between internal subcontext variable, to the name of a runtime variable (i.e. in init, step!, cleanup)
These will be embedded in IdentifiableAlgo objects to tell them how to map from context to their internal variables

As of now, this is only useful when algorithms are packaged because then subcontexts are shared
Otherwise variable names are sandboxed already by the namespace system and thus don't need aliasing

In some sense thay are analogous to Route objects but for variables internal to an algorithm instead of between contexts

There are two inverse mappings stored here:
    StoA: Subcontext to Algo mapping, i.e. from the subcontext variable name to the internal variable name
    AtoS: Algo to Subcontext mapping, i.e. from the internal variable name to the actual subcontext variable name
"""
struct VarAliases{StoA_nt, AtoS_nt} <: AbstractVarAlias end
externalnames(va::VarAliases{StoA_nt, AtoS_nt}) where {StoA_nt, AtoS_nt} = keys(StoA_nt)
internalnames(va::VarAliases{StoA_nt, AtoS_nt}) where {StoA_nt, AtoS_nt} = keys(AtoS_nt)
VarAliases(;subcontext_to_algo_names...) = VarAliases{(;subcontext_to_algo_names...), invert_nt((;subcontext_to_algo_names...))}()



@inline Base.@constprop :aggressive function subcontext_to_algo_names(va::Union{VarAliases{StoA_nt, AtoS_nt}, Type{<:VarAliases{StoA_nt, AtoS_nt}}}, name::Symbol) where {StoA_nt, AtoS_nt}
    if isempty(StoA_nt) || !haskey(StoA_nt, name)
        return name
    end
    @inline getproperty(StoA_nt, name)
end

@inline Base.@constprop :aggressive function algo_to_subcontext_names(va::Union{VarAliases{StoA_nt, AtoS_nt}, Type{<:VarAliases{StoA_nt, AtoS_nt}}}, name::Symbol) where {StoA_nt, AtoS_nt}
    if isempty(AtoS_nt) || !haskey(AtoS_nt, name)
        return name
    end
    @inline getproperty(AtoS_nt, name)
end

"""
No alias means the name is the same in the subcontext and the algo
"""
algo_to_subcontext_names(::Nothing, name) = name
"""
No alias means the name is the same in the subcontext and the algo
"""
subcontext_to_algo_names(::Nothing, name) = name

#######################################
######### Interface ###################
#######################################

function getvaraliases(a::Any)
    if a isa AbstractIdentifiableAlgo
        error("No getaliases method defined for $(typeof(a))")
    else 
        error("getaliases only works for AbstractIdentifiableAlgo, not $(typeof(a))")
    end
end
function setvaraliases(a, newaliases)
    if a isa AbstractIdentifiableAlgo
        error("No setaliases method defined for $(typeof(a))")
    else 
        error("setaliases only works for AbstractIdentifiableAlgo, not $(typeof(a))")
    end
end


##############################
######## State Alias #########
##############################

const state_regex = r"__.sa__"

"""
For dublicating state variables when packaging algorithms
    The postfix is used to make sure that the generated variable name doesn't conflict with any user defined variable names

A StateAlias will work two ways, writing state with the postfix into the subcontext
    and reading state with the postfix REMOVED when reading from the subcontext, so that the algorithm can use the original variable names


"""

struct StateAlias{postfix} end
StateAlias(postfix = uuid4()) = StateAlias{Symbol(state_regex,postfix)}()

@inline Base.@constprop :aggressive subcontext_to_algo_names(sd::Union{StateAlias{postfix}, Type{StateAlias{postfix}}}, name::Symbol) where {postfix} = subcontext_to_algo_names(sd, Val(name) )
@inline @generated function subcontext_to_algo_names(sd::Union{StateAlias{postfix}, Type{StateAlias{postfix}}}, name::Val{SubcontextName}) where {postfix, SubcontextName <:Symbol}
    subcontextnamestring = string(SubcontextName)
    if occursin(state_regex, subcontextnamestring)
        base = replace(subcontextnamestring, state_regex => "")
        viewname = Symbol(base)
        return :( $viewname )
    end
    return :(nothing)
end

@inline Base.@constprop :aggressive algo_to_subcontext_names(sd::Union{StateAlias{postfix}, Type{StateAlias{postfix}}}, name::Symbol) where {postfix} = algo_to_subcontext_names(sd, Val(name) )
@inline @generated function algo_to_subcontext_names(sd::Union{StateAlias{postfix}, Type{StateAlias{postfix}}}, name::Val{ViewName}) where {postfix, ViewName <:Symbol}
    viewnamestring = string(ViewName)
    subcontextname = Symbol(viewnamestring, state_regex, postfix)
    return :( $subcontextname )
end


