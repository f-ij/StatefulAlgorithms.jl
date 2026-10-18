export Routine, RoutinePlan

"""
Execution plan that repeats child algorithms.

`Routine` is the repeated counterpart to `CompositeAlgorithm`: it keeps child
algorithms, repeat metadata, namespaces, plan wiring, its own states and its other
options. Resume counters are allocated as loop cursors only for pausable executions.
"""
struct Routine{T, Repeats, Namespaces, W, id, S, O} <: AbstractPlan
    funcs::T
    repeats
    namespaces::Namespaces
    wiring::W
    states::S
    options::O
end

const RoutinePlan = Routine

function Routine(args...)
    parse_la_input(Routine, args...)
end


function newfuncs(r::Routine, funcs)
    setfield(r, :funcs, funcs)
end

"""Rebuild the route/share wiring of `r` from `wiring` (`Route`s, `Share`s, `LocalPlanOption`s)."""
function setwiring(r::Routine, wiring)
    # Declared locals are part of the plan's wiring; rebuilding the routes and shares keeps them.
    wiring = PlanWiring(_plan_wiring(wiring), _plan_child_wiring(getalgos(r), wiring), getfield(getwiring(r), :locals))
    return setfield(r, :wiring, wiring)
end

@inline getalgo(r::Routine, idx) = getalgos(r)[idx]
@inline subalgorithms(r::Routine) = getalgos(r)
statetypes(::Union{Routine{T,R,NS,W,id,S}, Type{<:Routine{T,R,NS,W,id,S}}}) where {T,R,NS,W,id,S} = S.parameters



"""Convert a routine lifetime schedule into registry multiplier weight."""
@inline _routine_schedule_multiplier(spec::RL) where {RL<:RepeatLifetime} = Float64(repeats(spec))
@inline _routine_schedule_multiplier(spec::IL) where {IL<:IndefiniteLifetime} = Inf

"""Return the numeric loop bound used by a routine child lifetime."""
@inline routine_repeat_count(spec::RL) where {RL<:RepeatLifetime} = repeats(spec)
@inline routine_repeat_count(spec::IL) where {IL<:IndefiniteLifetime} = typemax(Int)

"""Convert routine specification entries into registry multiplier weights."""
getmultipliers_from_specification_num(::Type{R}, specification_num::S) where {R<:Routine,S} =
    map(_routine_schedule_multiplier, specification_num)
resumable(r::Routine) = true

# TODO: This is only used in treesctructure, try to deprecate
subalgotypes(r::Routine{FT}) where FT = FT.parameters
subalgotypes(::Type{R}) where {FT, R<:Routine{FT}} = FT.parameters
algotypes(r::Union{Routine{FT}, Type{R}}) where {FT, R<:Routine{FT}} = tuple(FT.parameters...)
statetypes(r::Union{Routine, Type{<:Routine}}) = ()

# getnames(r::Routine{T, R, NT, N}) where {T, R, NT, N} = N
Base.length(r::Routine) = length(getalgos(r))

function reset!(r::Routine)
    reset!.(getalgos(r))
end
#############################################
################ Type Info ###############
#############################################

@inline functypes(r::Union{Routine{T,R,NS}, Type{<:Routine{T,R,NS}}}) where {T,R,NS} = tuple(T.parameters...)
@inline getalgotype(::Union{Routine{T,R,NS}, Type{<:Routine{T,R,NS}}}, idx) where {T,R,NS} = T.parameters[idx]
@inline numalgos(r::Union{Routine{T,R,NS}, Type{<:Routine{T,R,NS}}}) where {T,R,NS} = length(T.parameters)

"""Return registry multiplier weights for each routine child."""
multipliers(r::R) where {R<:Routine} = tuplemap(_routine_schedule_multiplier, lifetimes(r))
multipliers(rT::Type{R}) where {R<:Routine} = tuplemap(_routine_schedule_multiplier, lifetimes(rT))
getid(r::Union{Routine{T,R,NS,W,id},Type{<:Routine{T,R,NS,W,id}}}) where {T,R,NS,W,id} = id

"""Return the child lifetime schedule tuple for a routine."""
@inline lifetimes(r::Routine) = typeof(r).parameters[2]
@inline lifetimes(::Type{<:Routine{F,R}}) where {F,R} = R
lifetimes(r::Routine, idx::Int) = lifetimes(r)[idx]
lifetimes(r::Routine, ::Val{idx}) where {idx} = lifetimes(r)[idx]
lifetimes(r::Type{<:Routine}, idx::Int) = lifetimes(r)[idx]
lifetimes(r::Type{<:Routine}, ::Val{idx}) where {idx} = lifetimes(r)[idx]

"""Compatibility alias for the historical integer-only routine schedule API."""
@inline repeats(r::Union{Routine, Type{<:Routine}}) = map(repeats, lifetimes(r))
repeats(r::Union{Routine, Type{<:Routine}}, idx::Int) = repeats(lifetimes(r, idx))
repeats(r::Union{Routine, Type{<:Routine}}, idx::Val) = repeats(lifetimes(r, idx))

include("Hooks.jl")
