export Plan, CompositeAlgorithm, Routine, DefaultLifetime
export inc!, intervals, interval

#=
A plan: child algorithms stepped in order, each as its schedule entry says. `CompositeAlgorithm(...)` and `Routine(...)`
both build one; they differ only in what a plain number in the schedule means and in the default lifetime of a process.

Schedule entries (one per child, in the plan's `schedule` field):
1. interval entries, `Interval` and `RunIf`: the child runs at most once per step of the plan, when the plan's step
   count is due (and the condition holds). A pause is only seen between steps.
2. repeat entries, the `Lifetime`s (`Repeat(n)`, `Until(...)`, ...): the child runs all its repeats in every step of
   the plan. The process is checked for a pause after every repeat, and a paused step resumes there.
=#

"""
Execution plan: child algorithms (`funcs`) stepped in order, each as its entry in `schedule` says (an interval or a
repeat, see the file header). It stores the block as written: the children, their schedule, namespaces, its
route/share wiring (`getwiring`), its own states (`getstates`: `@state`, `@input`) and its other options (`getoptions`,
such as `RuntimeInputs`, `Redirect` and `DefaultLifetime`). What `resolve`, `init` and `run` add (the registry,
persistent context, inits, overrides and the loop cursor) belongs to the `LoopAlgorithm`/`PlanCursor` they create.
"""
struct Plan{T, Schedule, Namespaces, W, id, S, O} <: AbstractPlan
    funcs::T
    schedule::Schedule
    namespaces::Namespaces
    wiring::W
    states::S
    options::O
end

"""
    CompositeAlgorithm(children..., (entries...), states..., options...)

A `Plan` whose plain-number schedule entries are intervals (`3` is `Interval(3)`). Without entries every child runs
every step. Entries can be mixed: `CompositeAlgorithm(A, B, (2, Repeat(30)))` runs `A` every second step and `B` 30
times every step. Nested composites without wiring, states or options of their own are flattened into this one.
"""
Base.@nospecializeinfer CompositeAlgorithm(@nospecialize(args...)) = parse_la_input(Plan, Val(:interval), strip_unique(args)...)

"""
    Routine(children..., (entries...), states..., options...)

A `Plan` whose plain-number schedule entries are repeats (`3` is `Repeat(3)`); the entries are required. A process of
it runs one step unless given another lifetime (`DefaultLifetime(Repeat(1))`, added to its options).
"""
Base.@nospecializeinfer Routine(@nospecialize(args...)) = parse_la_input(Plan, Val(:repeat), strip_unique(args)...)

"""
    DefaultLifetime(lifetime)

Plan option: the lifetime a process of the plan gets when none is given. `Routine(...)` adds `DefaultLifetime(Repeat(1))`;
a plan without it runs `Indefinite()`. Only the outermost plan's option is read.
"""
struct DefaultLifetime{L<:Lifetime} <: AbstractOption
    lifetime::L
end

"""The `DefaultLifetime` among a plan's `options`, or `nothing`."""
Base.@nospecializeinfer function find_default_lifetime(@nospecialize(options::Tuple))
    for option in options
        option isa DefaultLifetime && return getfield(option, :lifetime)
    end
    return nothing
end

"""`true` when a schedule entry of type `E` repeats its child within a step (a `Lifetime`), `false` for an interval entry."""
is_repeat_entry(::Type{<:Lifetime}) = true
is_repeat_entry(::Type) = false

"""
`true` when a step of a child of type `T` can stop for a pause before it ends: a plan with a repeat entry, or with a
child that can. Its cursor then records where to resume (`PlanCursor`).
"""
has_pause_points(::Type) = false
has_pause_points(::Type{<:Plan{T, Schedule}}) where {T, Schedule} =
    any(is_repeat_entry, fieldtypes(Schedule)) || any(has_pause_points, fieldtypes(T))

function newfuncs(plan::Plan, funcs)
    setfield(plan, :funcs, funcs)
end

"""Rebuild the route/share wiring of `plan` from `wiring` (`Route`s, `Share`s, `LocalPlanOption`s)."""
function setwiring(plan::Plan, wiring)
    # Declared locals are part of the plan's wiring; rebuilding the routes and shares keeps them.
    wiring = PlanWiring(_build_plan_wiring(wiring), _build_child_wiring(getalgos(plan), wiring), getfield(getwiring(plan), :locals))
    return setfield(plan, :wiring, wiring)
end

algotypes(plan::Union{Plan{FT}, Type{<:Plan{FT}}}) where FT = FT.parameters
statetypes(::Union{Plan{T,Sch,NS,W,id,S}, Type{<:Plan{T,Sch,NS,W,id,S}}}) where {T,Sch,NS,W,id,S} = S.parameters
subalgotypes(plan::Plan{FT}) where FT = FT.parameters
subalgotypes(::Type{P}) where {FT, P<:Plan{FT}} = FT.parameters

getid(plan::Union{Plan{T,Sch,NS,W,id}, Type{<:Plan{T,Sch,NS,W,id}}}) where {T,Sch,NS,W,id} = id
setid(plan::P, id = uuid4()) where {P<:Plan} = setparameter(plan, 5, id)
hasid(plan::Union{Plan{T,Sch,NS,W,id}, Type{<:Plan{T,Sch,NS,W,id}}}) where {T,Sch,NS,W,id} = !isnothing(id)
id(plan::Union{Plan{T,Sch,NS,W,id}, Type{<:Plan{T,Sch,NS,W,id}}}) where {T,Sch,NS,W,id} = id

###########################################
################ Type Info ###############
###########################################
@inline functypes(plan::Union{Plan{T,Sch,NS}, Type{<:Plan{T,Sch,NS}}}) where {T,Sch,NS} = tuple(T.parameters...)
@inline getalgotype(::Union{Plan{T,Sch,NS}, Type{<:Plan{T,Sch,NS}}}, idx) where {T,Sch,NS} = T.parameters[idx]
@inline numalgos(::Union{Plan{T,Sch,NS}, Type{<:Plan{T,Sch,NS}}}) where {T,Sch,NS} = length(T.parameters)

Base.length(plan::Plan) = length(getalgos(plan))
Base.eachindex(plan::Plan) = eachindex(getalgos(plan))

#######################################
############ Schedule ##################
#######################################
"""The schedule entries of `plan` (its intervals and repeats), one per child."""
@inline intervals(plan::Plan) = getfield(plan, :schedule)
@inline intervals(plan::Plan, ::Val{Idx}) where Idx = @inline intervals(plan)[Idx]
interval(plan::Plan, idx) = getfield(plan, :schedule)[idx]

"""The repeat entries of `plan` (`Repeat(n)`, `Until(...)`, ...), as `intervals`."""
@inline lifetimes(plan::Plan) = getfield(plan, :schedule)
lifetimes(plan::Plan, idx::Int) = lifetimes(plan)[idx]
lifetimes(plan::Plan, ::Val{idx}) where {idx} = lifetimes(plan)[idx]

"""The repeat count of each child, for a plan whose entries are all repeats (`Inf` for one without a count)."""
@inline repeats(plan::Plan) = map(repeats, lifetimes(plan))
repeats(plan::Plan, idx::Int) = repeats(lifetimes(plan, idx))
repeats(plan::Plan, idx::Val) = repeats(lifetimes(plan, idx))

"""
The step count each interval entry of a plan of type `P` is due on, from the type alone (`Interval`'s type holds it); a
repeat entry runs every step and counts as 1.
"""
@inline interval_numbers(::Type{<:Plan{T,Sch}}) where {T,Sch} = map(E -> is_repeat_entry(E) ? 1 : getinterval(E), fieldtypes(Sch))

"""How often a child runs per step of its plan for schedule entry `entry`: `1/n` for an interval, the count for a repeat."""
@inline schedule_multiplier(entry::Union{Interval, RunIf}) = 1 / getinterval(entry)
@inline schedule_multiplier(entry::RepeatLifetime) = Float64(repeats(entry))
@inline schedule_multiplier(::IndefiniteLifetime) = Inf

"""The number of repeats a repeat entry runs, as a loop bound (`typemax(Int)` for one without a count)."""
@inline routine_repeat_count(spec::RL) where {RL<:RepeatLifetime} = repeats(spec)
@inline routine_repeat_count(spec::IL) where {IL<:IndefiniteLifetime} = typemax(Int)

multipliers(plan::Plan) = tuplemap(schedule_multiplier, getfield(plan, :schedule))

"""
Increment the step count of a plan's cursor.

The counter cycles through `1:lcm` of the interval entries. A compare/select wrap keeps the loop-carried counter off
the division path that `mod1` would put on every tick; with an lcm of 1 the counter never changes.
"""
@inline @generated function inc!(cursor::PlanCursor, plan::P) where P <: Plan
    _lcm = lcm(interval_numbers(P)...)
    _lcm == 1 && return :(nothing)
    return quote
        cainc = getinc(cursor)
        i = cainc[]
        cainc[] = ifelse(i >= $_lcm, 1, i + 1)
    end
end

"""The step count of a plan's cursor (1 when the plan's intervals never need it)."""
@inline inc(cursor::PlanCursor) = _inc_value(getinc(cursor))
@inline _inc_value(inc::Base.RefValue{Int}) = inc[]
@inline _inc_value(::Nothing) = 1
