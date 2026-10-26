export setrepeats, setintervals, setinterval

#=
Changing a plan's schedule: the interval or repeat entry of each child. A plan keeps its schedule in field 2, whose
type is type parameter 2. Every change goes through `setschedule`.
=#

"""The schedule of a plan (field 2): one interval or repeat entry per child."""
@inline getschedule(plan::AbstractPlan) = getfield(plan, 2)
@inline getschedule(la::LoopAlgorithm) = getschedule(getplan(la))

"""
    setschedule(plan, schedule) -> plan

`plan` with `schedule` in its schedule field (and its type as type parameter 2). Every id in `schedule` must be
numbered already (taken from this plan), as a new `Unique` handle is numbered only when a plan is built.
"""
Base.@nospecializeinfer function setschedule(@nospecialize(plan::AbstractPlan), @nospecialize(schedule))
    T = typeof(plan)
    schedule = store_single_repeats_as_repeat_once(schedule)
    params = Any[T.parameters...]
    params[2] = typeof(schedule)
    fields = Any[getfield(plan, i) for i in 1:nfields(plan)]
    fields[2] = schedule
    return new_instance(Core.apply_type(T.name.wrapper, params...), fields...)
end

"""
    store_single_repeats_as_repeat_once(schedule) -> schedule

A plan's `schedule` with each `Repeat(1)` entry as `RepeatOnce()`, whose type says the count, so the child's step has
no loop. The other entries are returned as they are.
"""
Base.@nospecializeinfer function store_single_repeats_as_repeat_once(@nospecialize(schedule))
    schedule isa Tuple || return schedule
    return Tuple(Any[x isa Repeat && repeats(x) == 1 ? RepeatOnce() : x for x in schedule])
end

"""`plan` with one entry per child from `new_entries`; a number becomes an `Interval` (`setintervals`) or a `Repeat` (`setrepeats`)."""
function setintervals(plan::Plan, new_entries)
    length(new_entries) == length(getalgos(plan)) || construction_assert_error("Length of new intervals must match number of functions in the plan, but got ", length(new_entries), " intervals for ", length(getalgos(plan)), " functions")
    return setschedule(plan, map(x -> _normalize_schedule_entry(Val(:interval), x), Tuple(new_entries)))
end
function setrepeats(plan::Plan, new_entries)
    length(new_entries) == length(getalgos(plan)) || construction_assert_error("Length of new repeats must match number of functions in the plan, but got ", length(new_entries), " repeats for ", length(getalgos(plan)), " functions")
    return setschedule(plan, map(x -> _normalize_schedule_entry(Val(:repeat), x), Tuple(new_entries)))
end

"""`plan` with the entry of child `idx` set to `new_interval` (a number becomes an `Interval`)."""
setinterval(plan::Plan, idx::Int, new_interval) =
    setschedule(plan, Base.setindex(getschedule(plan), _normalize_schedule_entry(Val(:interval), new_interval), idx))
"""`plan` with the entry of child `idx` set to `newrepeats` (a number becomes a `Repeat`)."""
setrepeats(plan::Plan, idx::Int, newrepeats) =
    setschedule(plan, Base.setindex(getschedule(plan), _normalize_schedule_entry(Val(:repeat), newrepeats), idx))

# `ThreadedCompositeAlgorithm`'s are in Threaded/CompositeAlgorithms.jl (included later).

_as_interval(i::Real) = Interval(i)
_as_interval(i) = i
