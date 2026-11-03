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

@inline init_lifetime(ic::InitContext) = getfield(ic, :lifetime)

# Interface.jl
persistent_type(::Type{<:InitContext{PersistentContextType}}) where {PersistentContextType} = PersistentContextType
@inline withpersistent(ic::InitContext, persistent_context::ProcessContext) = InitContext(persistent_context, getfield(ic, :algo), getfield(ic, :lifetime))
@inline _rebundle(ic::InitContext, persistent_context::ProcessContext, ::NamedTuple{()}) = withpersistent(ic, persistent_context)

# Hooks.jl
@inline bundle_lifetime(ic::InitContext) = init_lifetime(ic)
