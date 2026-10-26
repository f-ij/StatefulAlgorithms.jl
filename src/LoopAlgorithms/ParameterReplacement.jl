export setrepeats, setintervals, setinterval

#=
Changing a plan's schedule: the repeats of a `Routine`, the intervals of a composite. A plan keeps its schedule in
field 2, whose type is type parameter 2. Every change goes through `setschedule`.
=#

"""The schedule of a plan (field 2): a composite's intervals, a routine's repeats."""
@inline getschedule(plan::AbstractPlan) = getfield(plan, 2)
@inline getschedule(la::LoopAlgorithm) = getschedule(getplan(la))

"""
    setschedule(plan, schedule) -> plan

`plan` with `schedule` in its schedule field (and its type as type parameter 2). Every id in `schedule` must be
numbered already (taken from this plan), as a new `Unique` handle is numbered only when a plan is built.
"""
Base.@nospecializeinfer function setschedule(@nospecialize(plan::AbstractPlan), @nospecialize(schedule))
    T = typeof(plan)
    schedule = store_single_repeats_as_repeat_once(T, schedule)
    params = Any[T.parameters...]
    params[2] = typeof(schedule)
    fields = Any[getfield(plan, i) for i in 1:nfields(plan)]
    fields[2] = schedule
    return new_instance(Core.apply_type(T.name.wrapper, params...), fields...)
end

"""
    store_single_repeats_as_repeat_once(PlanType, schedule) -> schedule

A routine's `schedule` with each `Repeat(1)` as `RepeatOnce()`, whose type says the count, so the child's step has no
loop. Other plans' schedules are returned as they are.
"""
Base.@nospecializeinfer function store_single_repeats_as_repeat_once(@nospecialize(PlanType::Type), @nospecialize(schedule))
    (PlanType <: Routine && schedule isa Tuple) || return schedule
    return Tuple(Any[x isa Repeat && repeats(x) == 1 ? RepeatOnce() : x for x in schedule])
end

setrepeats(r::Routine, newrepeats) = setschedule(r, newrepeats)
setintervals(r::Routine, newintervals) = setschedule(r, newintervals)

function setintervals(ca::CompositeAlgorithm, new_intervals)
    length(new_intervals) == length(getalgos(ca)) || construction_assert_error("Length of new intervals must match number of functions in the composite algorithm, but got ", length(new_intervals), " intervals for ", length(getalgos(ca)), " functions")
    return setschedule(ca, Tuple(new_intervals))
end

"""`ca` with the interval of child `idx` set to `new_interval` (a number becomes an `Interval`)."""
setinterval(ca::CompositeAlgorithm, idx::Int, new_interval) =
    setschedule(ca, Base.setindex(getschedule(ca), _as_interval(new_interval), idx))
setrepeats(ca::CompositeAlgorithm, idx::Int, newrepeats) = setinterval(ca, idx, newrepeats)

# `ThreadedCompositeAlgorithm`'s are in Threaded/CompositeAlgorithms.jl (included later).

_as_interval(i::Real) = Interval(i)
_as_interval(i) = i
