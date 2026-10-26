export AbstractLoopCursor, NoLoopCursor, loop_cursor

"""Return the step count `Ref` of a plan's cursor (`nothing` when its plan never needs one)."""
@inline getinc(cursor::CompositeLoopCursor) = getfield(cursor, :inc)
@inline getinc(cursor::PlanCursor) = getfield(cursor, :inc)

"""Return one nested child cursor by generated child index."""
@inline child_loop_cursor(cursor::CompositeLoopCursor, ::Val{I}) where {I} =
    getfield(getfield(cursor, :children), I)
@inline child_loop_cursor(cursor::PlanCursor, ::Val{I}) where {I} =
    getfield(getfield(cursor, :children), I)


"""Return a fresh cursor sentinel for leaf algorithms."""
@inline loop_cursor(::Any, ::Val{Pausable} = Val(false)) where {Pausable} = NoLoopCursor()

"""Build a loop cursor from an executable wrapper by using its plan."""
@inline loop_cursor(la::LoopAlgorithm, pausable::Val{Pausable} = Val(false)) where {Pausable} =
    loop_cursor(getplan(la), pausable)

"""Build a loop cursor from a finalized wrapper by using its inner loop."""
@inline loop_cursor(fa::FinalizedAlgorithm, pausable::Val{Pausable} = Val(false)) where {Pausable} =
    loop_cursor(inneralgorithm(fa), pausable)

"""
Build a per-run cursor for a plan.

The generated body mirrors the plan's nesting, so a run allocates only what the plan needs: a step count when an
interval entry is due on fewer than every step, and a `PauseRecord` when the run can pause (`Pausable`) and the plan
has a pause point (`has_pause_points`).
"""
@generated function loop_cursor(plan::P, ::Val{Pausable} = Val(false)) where {P<:Plan, Pausable}
    children = Expr(:tuple, (:(@inline loop_cursor(getfield(@inline(getalgos(plan)), $i), Val($Pausable))) for i in 1:numalgos(P))...)
    inc = lcm(interval_numbers(P)...) == 1 ? nothing : :(Ref(1))
    pause = Pausable && has_pause_points(P) ? :(PauseRecord()) : nothing
    return :(PlanCursor($inc, $pause, $children))
end

#=
Pausing in the middle of a step. A step stops at a pause point (after a repeat of a repeat entry), and the cursor of
every plan it is in records where (`record_pause!`), from the innermost plan outwards. The next run starts with
`resume_step!` on the outermost plan, which continues each plan from its record (Step.jl, "Resuming").
=#

"""`true` when the step of the plan with this cursor stopped for a pause and has not resumed yet."""
@inline is_paused_in_step(cursor::PlanCursor{Inc, PauseRecord}) where {Inc} = getfield(getfield(cursor, :pause), :child) != 0
@inline is_paused_in_step(::AbstractLoopCursor) = false

"""
Record in `cursor` that its plan's step stopped in child `child`, to continue at repeat `repeat` with the `LoopContext`
`lc`. Kept out of line: it stores `lc` in an untyped field, which only a pause should pay for.
"""
@noinline function record_pause!(cursor::PlanCursor{Inc, PauseRecord}, child::Int, repeat::Int, lc) where {Inc}
    record = getfield(cursor, :pause)
    record.child = child
    record.repeat = repeat
    record.lc = lc
    return nothing
end
@inline record_pause!(::AbstractLoopCursor, ::Int, ::Int, lc) = nothing

"""Take the pause record of `cursor` (child, repeat, `LoopContext`) and clear it, so the step is no longer paused."""
function take_pause!(cursor::PlanCursor{Inc, PauseRecord}) where {Inc}
    record = getfield(cursor, :pause)
    taken = (record.child, record.repeat, record.lc)
    record.child, record.repeat, record.lc = 0, 0, nothing
    return taken
end
