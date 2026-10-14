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

@inline getalgos(r::Routine) = getfield(r, :funcs)
@inline getalgo(r::Routine, idx) = getalgos(r)[idx]
@inline getwiring(r::Routine) = getfield(r, :wiring)
@inline getoptions(r::Routine) = getfield(r, :options)
@inline subalgorithms(r::Routine) = getalgos(r)
@inline getstates(r::Routine) = getfield(r, :states)
statetypes(::Union{Routine{T,R,NS,W,id,S}, Type{<:Routine{T,R,NS,W,id,S}}}) where {T,R,NS,W,id,S} = S.parameters



"""Convert a routine lifetime schedule into registry multiplier weight."""
@inline _routine_schedule_multiplier(spec::RL) where {RL<:RepeatLifetime} = Float64(repeats(spec))
@inline _routine_schedule_multiplier(spec::IL) where {IL<:IndefiniteLifetime} = Inf

"""Return the numeric loop bound used by a routine child lifetime."""
@inline routine_repeat_count(spec::RL) where {RL<:RepeatLifetime} = repeats(spec)
@inline routine_repeat_count(spec::IL) where {IL<:IndefiniteLifetime} = typemax(Int)

"""
    _routine_breakcondition(child_lifetime, process, context, done)

Whether a routine child's own stop condition (`Until`, `RepeatOrUntil`, `AtLeast`, `AtLeastAtMost`) holds, with `done`
repeats of the child done (in this step): the child is finished. Checked before each repeat, as a `while` loop's
condition (if it already holds, the child does not run). Always `false` for `Repeat` and `Indefinite`. A pause or close
of the process is `_process_breakcondition`.
"""
@inline _routine_breakcondition(spec::R, process::P, context::C, done::LI) where {R<:Repeat,P<:AbstractProcess,C,LI<:Integer} = false
@inline _routine_breakcondition(spec::IL, process::P, context::C, done::LI) where {IL<:Indefinite,P<:AbstractProcess,C,LI<:Integer} = false
@inline _routine_breakcondition(spec::U, process::P, context::C, done::LI) where {Vars,U<:Until{Vars},P<:AbstractProcess,C,LI<:Integer} =
    spec.cond(getindex(context, Vars...))
@inline _routine_breakcondition(spec::ROU, process::P, context::C, done::LI) where {Vars,ROU<:RepeatOrUntil{Vars},P<:AbstractProcess,C,LI<:Integer} =
    spec.cond(getindex(context, Vars...))
@inline _routine_breakcondition(spec::AL, process::P, context::C, done::LI) where {Vars,AL<:AtLeast{Vars},P<:AbstractProcess,C,LI<:Integer} =
    done >= spec.atleast && spec.cond(getindex(context, Vars...))
@inline _routine_breakcondition(spec::AAM, process::P, context::C, done::LI) where {Vars,AAM<:AtLeastAtMost{Vars},P<:AbstractProcess,C,LI<:Integer} =
    done >= spec.atleast && spec.cond(getindex(context, Vars...))

"""
    _process_breakcondition(lifetime, process, context)

Whether the process stops (`breakcondition` of its lifetime: for `Repeat`, a pause or close, `!shouldrun(process)`), as
checked inside a routine: after every repeat of a child. Repeats can run for a very long time, so a pause or close of a
`Process` must be seen between any two of them, not once per child. See `shouldrun(::Process)`. The child's own stop
condition is `_routine_breakcondition`.
"""
@inline _process_breakcondition(lifetime::LT, process::P, context::C) where {LT<:Lifetime,P<:AbstractProcess,C} =
    @inline breakcondition(lifetime, process, context)

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

