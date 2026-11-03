#=
`InitContext`: the bundle init works on. Sections, in order: the type, and at the end the methods of the bundle
Interface (Interface.jl) and of the bundle hooks (Hooks.jl).
=#

##########################################
################## Type ##################
##########################################

"""
    InitContext(persistent_context, algo, lifetime)

What init works on. Init runs before the loop starts, so there is no runtime context yet.

It holds the persistent context that init is filling in, the algorithm being prepared, and the run's lifetime. The
lifetime is there so init can size buffers by the number of steps (`processsizehint!`).
"""
struct InitContext{PersistentContextType<:ProcessContext, AlgoType, LifetimeType} <: ContextBundle
    persistent::PersistentContextType
    algo::AlgoType
    lifetime::LifetimeType
end

##########################################
########## Interface extensions ##########
##########################################

persistent_type(::Type{<:InitContext{PersistentContextType}}) where {PersistentContextType} = PersistentContextType
@inline withpersistent(ic::IC, persistent_context::PC) where {IC<:InitContext, PC<:ProcessContext} = InitContext(persistent_context, getfield(ic, :algo), getfield(ic, :lifetime))
@inline rebundle(ic::IC, persistent_context::PC, ::NamedTuple{()}) where {IC<:InitContext, PC<:ProcessContext} = withpersistent(ic, persistent_context)

##########################################
############ Hook extensions #############
##########################################

@inline bundle_lifetime(ic::IC) where {IC<:InitContext} = getfield(ic, :lifetime)
