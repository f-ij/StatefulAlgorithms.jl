export Routine, RoutinePlan

"""
Execution plan that repeats child algorithms.

`Routine` is the repeated counterpart to `CompositeAlgorithm`: it keeps child
algorithms, repeat metadata, resume counters, and plan wiring. The runtime
registry, root states, context, inputs, and overrides are carried by the concrete
`LoopAlgorithm` wrapper.
"""
struct Routine{T, Repeats, Namespaces, MV, W, id} <: AbstractLoopAlgorithm
    funcs::T     
    repeats
    namespaces::Namespaces
    resume_idxs::MV
    wiring::W
end

const RoutinePlan = Routine

function Routine(args...)
    parse_la_input(Routine, args...)
end

"""
Construct a routine execution plan, wrapping it only when root runtime data exists.

`LocalPlanOption` route/share metadata is stored in per-child wiring; plain
route/share wiring is stored on the plan. Root states and other
non-plan options remain on the `LoopAlgorithm` wrapper.
"""
function LoopAlgorithm(::Type{Routine}, funcs::F, states::Tuple, options::Tuple, repeats; id = nothing) where F
    namespaces = ntuple(_ -> Namespace{nothing}(), length(funcs))
    resume_idxs = MVector{length(funcs),Int}(ones(length(funcs)))
    wiring = PlanWiring(_plan_wiring(options), _plan_child_wiring(funcs, options))
    plan = Routine{typeof(funcs), repeats, typeof(namespaces), typeof(resume_idxs), typeof(wiring), id}(funcs, repeats, namespaces, resume_idxs, wiring)
    root_options = _root_loop_options(options)
    return isempty(states) && isempty(root_options) ? plan : LoopAlgorithm(plan; states, options = root_options, id)
end

function newfuncs(r::Routine, funcs)
    setfield(r, :funcs, funcs)
end

function setoptions(r::Routine, options)
    wiring = PlanWiring(_plan_wiring(options), _plan_child_wiring(getalgos(r), options))
    return setfield(r, :wiring, wiring)
end

@inline getalgos(r::Routine) = getfield(r, :funcs)
@inline getalgo(r::Routine, idx) = getalgos(r)[idx]
@inline getwiring(r::Routine) = getfield(r, :wiring)
@inline getoptions(r::Routine) = _all_plan_wiring(global_wiring(getwiring(r)), child_wiring(getwiring(r)))
@inline subalgorithms(r::Routine) = getalgos(r)
@inline getstates(r::Routine) = ()



"""Convert a routine lifetime schedule into registry multiplier weight."""
@inline _routine_schedule_multiplier(spec::RL) where {RL<:RepeatLifetime} = Float64(repeats(spec))
@inline _routine_schedule_multiplier(spec::IL) where {IL<:IndefiniteLifetime} = Inf

"""Return the numeric loop bound used by a routine child lifetime."""
@inline routine_repeat_count(spec::RL) where {RL<:RepeatLifetime} = repeats(spec)
@inline routine_repeat_count(spec::IL) where {IL<:IndefiniteLifetime} = typemax(Int)

"""Return whether a routine-local child schedule has stopped the current child."""
@inline _routine_local_breakcondition(spec::R, process::P, context::C, lidx::LI) where {R<:Repeat,P<:AbstractProcess,C,LI<:Integer} = false
@inline _routine_local_breakcondition(spec::IL, process::P, context::C, lidx::LI) where {IL<:Indefinite,P<:AbstractProcess,C,LI<:Integer} = false
@inline _routine_local_breakcondition(spec::U, process::P, context::C, lidx::LI) where {Vars,U<:Until{Vars},P<:AbstractProcess,C,LI<:Integer} =
    spec.cond(getindex(context, Vars...))
@inline _routine_local_breakcondition(spec::ROU, process::P, context::C, lidx::LI) where {Vars,ROU<:RepeatOrUntil{Vars},P<:AbstractProcess,C,LI<:Integer} =
    spec.cond(getindex(context, Vars...))
@inline _routine_local_breakcondition(spec::AL, process::P, context::C, lidx::LI) where {Vars,AL<:AtLeast{Vars},P<:AbstractProcess,C,LI<:Integer} =
    lidx > spec.atleast && spec.cond(getindex(context, Vars...))
@inline _routine_local_breakcondition(spec::AAM, process::P, context::C, lidx::LI) where {Vars,AAM<:AtLeastAtMost{Vars},P<:AbstractProcess,C,LI<:Integer} =
    lidx > spec.atleast && spec.cond(getindex(context, Vars...))

"""
Return whether a routine child should stop.

Routine-local lifetimes are checked before the top-level process lifetime so
child completion does not get treated as a process interruption.
"""
@inline function routine_breakcondition(subroutine_lifetime::SL, lifetime::LT, process::P, context::C, lidx::LI) where {SL,LT<:Lifetime,P<:AbstractProcess,C,LI<:Integer}
    if @inline _routine_local_breakcondition(subroutine_lifetime, process, context, lidx)
        return true
    end
    return @inline breakcondition(lifetime, process, context)
end

"""Convert routine specification entries into registry multiplier weights."""
getmultipliers_from_specification_num(::Type{R}, specification_num::S) where {R<:Routine,S} =
    map(_routine_schedule_multiplier, specification_num)
get_resume_idxs(r::Routine) = getfield(r, :resume_idxs)
resume_idx(r::Routine, idx) = getfield(r, :resume_idxs)[idx]
resumable(r::Routine) = true

# TODO: This is only used in treesctructure, try to deprecate
subalgotypes(r::Routine{FT}) where FT = FT.parameters
subalgotypes(::Type{R}) where {FT, R<:Routine{FT}} = FT.parameters
algotypes(r::Union{Routine{FT}, Type{R}}) where {FT, R<:Routine{FT}} = tuple(FT.parameters...)
statetypes(r::Union{Routine, Type{<:Routine}}) = ()

# getnames(r::Routine{T, R, NT, N}) where {T, R, NT, N} = N
Base.length(r::Routine) = length(getalgos(r))

function reset!(r::Routine)
    getfield(r, :resume_idxs) .= 1
    reset!.(getalgos(r))
end
#############################################
################ Type Info ###############
#############################################

@inline functypes(r::Union{Routine{T,R,NS}, Type{<:Routine{T,R,NS}}}) where {T,R,NS} = tuple(T.parameters...)
@inline getalgotype(::Union{Routine{T,R,NS}, Type{<:Routine{T,R,NS}}}, idx) where {T,R,NS} = T.parameters[idx]
@inline numalgos(r::Union{Routine{T,R,NS}, Type{<:Routine{T,R,NS}}}) where {T,R,NS} = length(T.parameters)

"""Return registry multiplier weights for each routine child."""
multipliers(r::R) where {R<:Routine} = map(_routine_schedule_multiplier, lifetimes(r))
multipliers(rT::Type{R}) where {R<:Routine} = map(_routine_schedule_multiplier, lifetimes(rT))
getid(r::Union{Routine{T,R,NS,MV,W,id},Type{<:Routine{T,R,NS,MV,W,id}}}) where {T,R,NS,MV,W,id} = id

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



function resume_idxs(r::Routine)
    getfield(r, :resume_idxs)
end

function set_resume_point!(r::Routine, idx::Int, loopidx::Int)
    getfield(r, :resume_idxs)[idx] = loopidx
end

@inline function get_resume_point(r::Routine, idx::Int)
    getfield(r, :resume_idxs)[idx]
end
