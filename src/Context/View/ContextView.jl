export getglobals, withaliases
#################################
########## Properties ###########
#################################
varaliases(scv::Union{SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases}, Type{<:SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases}}}) where {CType, SubKey, RuntimeCType, T, NT, Aliases} = Aliases
view_sharedcontexts(scv::Union{SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases, SharedContexts}, Type{<:SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases, SharedContexts}}}) where {CType, SubKey, RuntimeCType, T, NT, Aliases, SharedContexts} = SharedContexts
view_sharedvars(scv::Union{SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases, SharedContexts, SharedVars}, Type{<:SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases, SharedContexts, SharedVars}}}) where {CType, SubKey, RuntimeCType, T, NT, Aliases, SharedContexts, SharedVars} = SharedVars

@inline this_instance(scv::SubContextView) = getfield(scv, :instance)

"""Return the lifetime carried by the active view runtime frame."""
@inline view_lifetime(scv::SubContextView) = getproperty(getglobals(getruntimecontext(scv)), :lifetime)

"""Return the process carried by the active view runtime frame."""
@inline view_process(scv::SubContextView) = getproperty(getglobals(getruntimecontext(scv)), :process)

"""Return the scheduled call multiplier for this view's owner."""
@inline view_multiplier(scv::SubContextView) = getmultiplier(scv, this_instance(scv))

@inline getglobals(scv::SubContextView) = getglobals(getruntimecontext(scv))
@inline getglobals(scv::SubContextView, name::Symbol) = getglobals(getruntimecontext(scv), name)

@inline getcontext(scv::SubContextView) = @inline getfield(scv, :context)
@inline getruntimecontext(scv::SubContextView) = @inline getfield(scv, :runtimecontext)
@inline getsubcontext(scv::SubContextView{CType, SubKey}) where {CType, SubKey} = @inline getproperty(getcontext(scv), SubKey)


getinjected(scv::SubContextView) = getfield(scv, :injected)
injectedfieldnames(scvt::Union{SubContextView{CType, SubKey, RuntimeCType, T, NT}, Type{<:SubContextView{CType, SubKey, RuntimeCType, T, NT}}}) where {CType, SubKey, RuntimeCType, T, NT} = fieldnames(NT)


"""
Helper to merge into a subcontext target in a namedtuple
    Merge nt's are (;targetsubcontext => (;targetname1 = value1, targetname2 = value2,...),...)

This merges a set of named tuples into the appropriate subcontexts in the provided context
"""
function algo_to_subcontext_names(scv::Union{SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases}, Type{<:SubContextView{CType, SubKey, RuntimeCType, T, NT, Aliases}}}, name::Symbol) where {CType, SubKey, RuntimeCType, T, NT, Aliases}
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
    scv::SubContextView{CType, SubKey, RuntimeCType, T, NT, OldAliases, SharedContexts, SharedVars},
    ::Type{Alias},
) where {CType, SubKey, RuntimeCType, T, NT, OldAliases, SharedContexts, SharedVars, Alias}
    typed_alias = @inline _alias_from_type(Alias)
    return SubContextView{CType, SubKey, RuntimeCType, T, NT, typeof(typed_alias), SharedContexts, SharedVars}(getcontext(scv), getruntimecontext(scv), this_instance(scv), getinjected(scv))
end

@inline function withaliases(scv::SubContextView, alias::Alias) where {Alias}
    return @inline withaliases(scv, Alias)
end

@inline function withaliases(
    scv::SubContextView{CType, SubKey, RuntimeCType, OldT, OldNT, OldAliases, SharedContexts, SharedVars},
    instance::T,
    injected::NT,
    ::Type{Alias},
) where {CType, SubKey, RuntimeCType, OldT, OldNT, OldAliases, SharedContexts, SharedVars, T, NT, Alias}
    typed_alias = @inline _alias_from_type(Alias)
    return SubContextView{CType, SubKey, RuntimeCType, T, NT, typeof(typed_alias), SharedContexts, SharedVars}(getcontext(scv), getruntimecontext(scv), instance, injected)
end

@inline function withaliases(scv::SubContextView, instance, injected, alias::Alias) where {Alias}
    return @inline withaliases(scv, instance, injected, Alias)
end

@inline function Base.view(pc::PC, runtimecontext::RC, instance::SA, inject::I, ::Tuple{}, ::Tuple{}) where {PC<:ProcessContext, RC<:ProcessContext, SA<:AbstractIdentifiableAlgo, I}
    key = @inline getkey(instance)
    return SubContextView{typeof(pc), key, typeof(runtimecontext), typeof(instance), typeof(inject)}(pc, runtimecontext, instance; inject)
end

@inline function Base.view(pc::PC, runtimecontext::RC, instance::SA, inject::I, sharedcontexts::SC, sharedvars::SV) where {PC<:ProcessContext, RC<:ProcessContext, SA<:AbstractIdentifiableAlgo, I, SC<:Tuple, SV<:Tuple}
    key = @inline getkey(instance)
    typed_sharedcontexts = @inline wiring_from_tuple_type(SC)
    typed_sharedvars = @inline wiring_from_tuple_type(SV)
    return SubContextView{typeof(pc), key, typeof(runtimecontext), typeof(instance), typeof(inject), varaliases(instance), typed_sharedcontexts, typed_sharedvars}(pc, runtimecontext, instance, inject)
end

@inline function Base.view(pc::PC, runtimecontext::RC, instance::A, ::Namespace{Name}, inject::I, ::Tuple{}, ::Tuple{}) where {PC<:ProcessContext, RC<:ProcessContext, A<:ProcessAlgorithm, Name, I}
    aliases = VarAliases()
    return SubContextView{typeof(pc), Name, typeof(runtimecontext), typeof(instance), typeof(inject), typeof(aliases), (), ()}(pc, runtimecontext, instance, inject)
end

@inline function Base.view(pc::PC, runtimecontext::RC, instance::A, ::Namespace{Name}, inject::I, sharedcontexts::SC, sharedvars::SV) where {PC<:ProcessContext, RC<:ProcessContext, A<:ProcessAlgorithm, Name, I, SC<:Tuple, SV<:Tuple}
    aliases = VarAliases()
    typed_sharedcontexts = @inline wiring_from_tuple_type(SC)
    typed_sharedvars = @inline wiring_from_tuple_type(SV)
    return SubContextView{typeof(pc), Name, typeof(runtimecontext), typeof(instance), typeof(inject), typeof(aliases), typed_sharedcontexts, typed_sharedvars}(pc, runtimecontext, instance, inject)
end

"""Get a subcontext view for a raw child algorithm and explicit namespace."""
@inline function Base.view(pc::ProcessContext, instance::A, namespace::Namespace; inject = (;), sharedcontexts = (), sharedvars = ()) where {A<:ProcessAlgorithm}
    return @inline view(pc, pc, instance, namespace, inject, sharedcontexts, sharedvars)
end

"""Get a subcontext view for a raw child algorithm with explicit runtime state."""
@inline function Base.view(pc::ProcessContext, runtimecontext::ProcessContext, instance::A, namespace::Namespace; inject = (;), sharedcontexts = (), sharedvars = ()) where {A<:ProcessAlgorithm}
    return @inline view(pc, runtimecontext, instance, namespace, inject, sharedcontexts, sharedvars)
end

"""
Get a subcontext view for a specific subcontext
"""
@inline function Base.view(pc::ProcessContext, instance::SA; inject = (;), sharedcontexts = (), sharedvars = ()) where SA <: AbstractIdentifiableAlgo
    # TODO: no key should always be nothing
    # if key == Symbol() || isnothing(key)
    #     key = getkey(getregistry(pc)[instance])
    # end
    return @inline view(pc, pc, instance, inject, sharedcontexts, sharedvars)
end

"""Get a subcontext view for a specific subcontext with explicit runtime state."""
@inline function Base.view(pc::ProcessContext, runtimecontext::ProcessContext, instance::SA; inject = (;), sharedcontexts = (), sharedvars = ()) where SA <: AbstractIdentifiableAlgo
    return @inline view(pc, runtimecontext, instance, inject, sharedcontexts, sharedvars)
end

@inline function Base.view(pc::ProcessContext{D}, instance::AbstractIdentifiableAlgo{T, nothing}, inject = (;)) where {D, T}
    named_instance = getregistry(pc)[instance]
    return view(pc, named_instance; inject)
end

"""
Create a view from a non-scoped instance by looking it up in the registry
"""
@inline function Base.view(pc::ProcessContext, instance::I, inject = (;)) where I
    reg = getregistry(pc)
    scoped_instance = @inline get(reg, instance, nothing)
    if isnothing(scoped_instance) && instance isa ProcessEntity
        scoped_instance = @inline static_get(reg, typeof(instance))
    elseif isnothing(scoped_instance)
        scoped_instance = @inline static_get(reg, instance)
    end
    runtimecontext = pc
    return SubContextView{typeof(pc), getkey(scoped_instance), typeof(runtimecontext), typeof(scoped_instance), typeof(inject)}(pc, runtimecontext, scoped_instance; inject=inject)
end

"""
Regenerate a SubContextView from its type
"""
@inline function Base.view(pc::PC, scv::CV; inject = (;)) where {PC <: ProcessContext, CV <: SubContextView}
    @inline view(pc, getruntimecontext(scv), this_instance(scv), inject(scv))
end

"""
View a view
"""
@inline function Base.view(scv::SubContextView{C,SubKey}, instance::SA) where {C, SubKey, SA <: AbstractIdentifiableAlgo}
    scoped_instance = @inline static_get(getregistry(scv), instance)
    scopename = getkey(scoped_instance)
    @assert scopename == SubKey "Trying to view SubContextView of subcontext $(SubKey) with instance of subcontext $(scopename)"
    context = getcontext(scv)
    return view(context, getruntimecontext(scv), instance)
end


##########################################
################# TYPES ##################
##########################################

"""
Get the type of the original subcontext from the view
"""
@inline subcontext_type(scv::Union{SubContextView{CType, SubKey}, Type{<:SubContextView{CType, SubKey}}}) where {CType<:ProcessContext, SubKey} = subcontext_type(CType, SubKey)



##########################################
############### MERGING ##################
##########################################

"""
Fallback merge if nothing is merged that just returns the original context
"""
@inline Base.merge(scv::SubContextView, ::Nothing) = getcontext(scv)
@inline Base.merge(scv::SubContextView, args) = error("Step, init and cleanup must return namedtuple, trying to merge $(args) into context from SubContextView $(scv)")
"""
Merge, but return view, useful for injecting variables that are not meant to be in the full context
"""
@inline inject(scv::SubContextView, args::NamedTuple) = @inline setfield(scv, :injected, merge(getinjected(scv), args))

####################################
############## SHOW ################
####################################

function Base.show(io::IO, scv::SubContextView{CType, SubKey}) where {CType, SubKey}
    print(io, "SubContextView(", SubKey, ")")
end
