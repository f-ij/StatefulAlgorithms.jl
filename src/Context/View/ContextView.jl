export get_captured_returns, withaliases
#################################
########## Properties ###########
#################################
varaliases(scv::Union{SubContextView{B, SubKey, T, NT, Aliases}, Type{<:SubContextView{B, SubKey, T, NT, Aliases}}}) where {B<:ContextBundle, SubKey, T, NT, Aliases} = Aliases
view_sharedcontexts(scv::Union{SubContextView{B, SubKey, T, NT, Aliases, SharedContexts}, Type{<:SubContextView{B, SubKey, T, NT, Aliases, SharedContexts}}}) where {B<:ContextBundle, SubKey, T, NT, Aliases, SharedContexts} = SharedContexts
view_sharedvars(scv::Union{SubContextView{B, SubKey, T, NT, Aliases, SharedContexts, SharedVars}, Type{<:SubContextView{B, SubKey, T, NT, Aliases, SharedContexts, SharedVars}}}) where {B<:ContextBundle, SubKey, T, NT, Aliases, SharedContexts, SharedVars} = SharedVars

@inline this_instance(scv::SubContextView) = getfield(scv, :instance)

"""The lifetime of the run being prepared: only while init runs (see `InitContext`), for sizing."""
@inline view_lifetime(scv::SubContextView) = @inline bundle_lifetime(getbundle(scv))

"""Return the scheduled call multiplier for this view's owner."""
@inline view_multiplier(scv::SubContextView) = getmultiplier(scv, this_instance(scv))

@inline get_captured_returns(scv::SubContextView) = @inline get_part_data(getbundle(scv), CapturedReturns())
@inline get_captured_returns(scv::SubContextView, name::Symbol) = getproperty(get_captured_returns(scv), name)

@inline getbundle(scv::SubContextView) = @inline getfield(scv, :bundle)
@inline getpersistent(scv::SubContextView) = @inline getpersistent(getbundle(scv))
@inline getsubcontext(scv::SubContextView{B, SubKey}) where {B<:ContextBundle, SubKey} = @inline getproperty(getpersistent(scv), SubKey)


getinjected(scv::SubContextView) = getfield(scv, :injected)
injectedfieldnames(scvt::Union{SubContextView{B, SubKey, T, NT}, Type{<:SubContextView{B, SubKey, T, NT}}}) where {B<:ContextBundle, SubKey, T, NT} = fieldnames(NT)


"""
Helper to merge into a subcontext target in a namedtuple
    Merge nt's are (;targetsubcontext => (;targetname1 = value1, targetname2 = value2,...),...)

This merges a set of named tuples into the appropriate subcontexts in the provided context
"""
function algo_to_subcontext_names(scv::Union{SubContextView{B, SubKey, T, NT, Aliases}, Type{<:SubContextView{B, SubKey, T, NT, Aliases}}}, name::Symbol) where {B<:ContextBundle, SubKey, T, NT, Aliases}
    _aliases = varaliases(scv)
    return @inline algo_to_subcontext_names(_aliases, name)
end

#################################
####### CREATING VIEWS ##########
#################################

"""Rebuild a tuple of resolved wiring values from its tuple type."""
@inline @generated function wiring_from_tuple_type(::Type{T}) where {T<:Tuple}
    return Expr(:tuple, (:( $(T.parameters[i])() ) for i in eachindex(T.parameters))...)
end

@inline _alias_from_type(::Type{Alias}) where {Alias} = Alias()

"""
Return `scv` with its view-local alias type replaced by `alias`.

The alias value is reconstructed from the concrete alias type instead of using
the runtime object. This keeps alias dispatch tied to type information and lets
view property lookup specialize on the alias mapping.
"""
@inline function withaliases(
    scv::SubContextView{B, SubKey, T, NT, OldAliases, SharedContexts, SharedVars},
    ::Type{Alias},
) where {B<:ContextBundle, SubKey, T, NT, OldAliases, SharedContexts, SharedVars, Alias}
    typed_alias = @inline _alias_from_type(Alias)
    return SubContextView{B, SubKey, T, NT, typeof(typed_alias), SharedContexts, SharedVars}(getbundle(scv), this_instance(scv), getinjected(scv))
end

@inline function withaliases(scv::SubContextView, alias::Alias) where {Alias}
    return @inline withaliases(scv, Alias)
end

@inline function withaliases(
    scv::SubContextView{B, SubKey, OldT, OldNT, OldAliases, SharedContexts, SharedVars},
    instance::T,
    injected::NT,
    ::Type{Alias},
) where {B<:ContextBundle, SubKey, OldT, OldNT, OldAliases, SharedContexts, SharedVars, T, NT, Alias}
    typed_alias = @inline _alias_from_type(Alias)
    return SubContextView{B, SubKey, T, NT, typeof(typed_alias), SharedContexts, SharedVars}(getbundle(scv), instance, injected)
end

@inline function withaliases(scv::SubContextView, instance, injected, alias::Alias) where {Alias}
    return @inline withaliases(scv, instance, injected, Alias)
end

@inline function Base.view(b::B, instance::SA, inject::I, ::Tuple{}, ::Tuple{}) where {B<:ContextBundle, SA<:AbstractIdentifiableAlgo, I}
    key = @inline getkey(instance)
    return SubContextView{B, key, typeof(instance), typeof(inject)}(b, instance; inject)
end

@inline function Base.view(b::B, instance::SA, inject::I, sharedcontexts::SC, sharedvars::SV) where {B<:ContextBundle, SA<:AbstractIdentifiableAlgo, I, SC<:Tuple, SV<:Tuple}
    key = @inline getkey(instance)
    typed_sharedcontexts = @inline wiring_from_tuple_type(SC)
    typed_sharedvars = @inline wiring_from_tuple_type(SV)
    return SubContextView{B, key, typeof(instance), typeof(inject), varaliases(instance), typed_sharedcontexts, typed_sharedvars}(b, instance, inject)
end

@inline function Base.view(b::B, instance::A, ::Namespace{Name}, inject::I, ::Tuple{}, ::Tuple{}) where {B<:ContextBundle, A<:ProcessAlgorithm, Name, I}
    aliases = VarAliases()
    return SubContextView{B, Name, typeof(instance), typeof(inject), typeof(aliases), (), ()}(b, instance, inject)
end

@inline function Base.view(b::B, instance::A, ::Namespace{Name}, inject::I, sharedcontexts::SC, sharedvars::SV) where {B<:ContextBundle, A<:ProcessAlgorithm, Name, I, SC<:Tuple, SV<:Tuple}
    aliases = VarAliases()
    typed_sharedcontexts = @inline wiring_from_tuple_type(SC)
    typed_sharedvars = @inline wiring_from_tuple_type(SV)
    return SubContextView{B, Name, typeof(instance), typeof(inject), typeof(aliases), typed_sharedcontexts, typed_sharedvars}(b, instance, inject)
end

"""The view of a raw child algorithm in namespace `namespace`, with the shares and routes of its wiring."""
@inline function Base.view(b::ContextBundle, instance::A, namespace::Namespace; inject = (;), sharedcontexts = (), sharedvars = ()) where {A<:ProcessAlgorithm}
    return @inline view(b, instance, namespace, inject, sharedcontexts, sharedvars)
end

"""The view of a keyed algorithm or state (an identifiable wrapper)."""
@inline function Base.view(b::ContextBundle, instance::SA; inject = (;), sharedcontexts = (), sharedvars = ()) where SA <: AbstractIdentifiableAlgo
    return @inline view(b, instance, inject, sharedcontexts, sharedvars)
end

"""
View a view
"""
@inline function Base.view(scv::SubContextView{B, SubKey}, instance::SA) where {B<:ContextBundle, SubKey, SA <: AbstractIdentifiableAlgo}
    scoped_instance = @inline static_get(getregistry(scv), instance)
    scopename = getkey(scoped_instance)
    @assert scopename == SubKey "Trying to view SubContextView of subcontext $(SubKey) with instance of subcontext $(scopename)"
    return view(getbundle(scv), instance)
end


##########################################
################# TYPES ##################
##########################################

"""
Get the type of the original subcontext from the view
"""
@inline subcontext_type(scv::Union{SubContextView{B, SubKey}, Type{<:SubContextView{B, SubKey}}}) where {B<:ContextBundle, SubKey} = subcontext_type(persistent_type(B), SubKey)



##########################################
############### MERGING ##################
##########################################

@inline Base.merge(scv::SubContextView, args) = error("Step, init and cleanup must return namedtuple, trying to merge $(args) into context from SubContextView $(scv)")
"""
Merge, but return view, useful for injecting variables that are not meant to be in the full context
"""
@inline inject(scv::SubContextView, args::NamedTuple) = @inline setfield(scv, :injected, merge(getinjected(scv), args))

####################################
############## SHOW ################
####################################

function Base.show(io::IO, scv::SubContextView{B, SubKey}) where {B<:ContextBundle, SubKey}
    print(io, "SubContextView(", SubKey, ")")
end
