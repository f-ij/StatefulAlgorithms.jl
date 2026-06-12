export AbstractLoopCursor, NoLoopCursor, loop_cursor

"""Return the mutable interval cursor stored for one composite runtime."""
@inline getinc(cursor::CompositeLoopCursor) = getfield(cursor, :inc)

"""Return one nested child cursor by generated child index."""
@inline child_loop_cursor(cursor::CompositeLoopCursor, ::Val{I}) where {I} =
    getfield(getfield(cursor, :children), I)
@inline child_loop_cursor(cursor::DirectRoutineCursor, ::Val{I}) where {I} =
    getfield(getfield(cursor, :children), I)
@inline child_loop_cursor(cursor::PausableRoutineCursor, ::Val{I}) where {I} =
    getfield(getfield(cursor, :children), I)

"""Return a fresh cursor sentinel for leaf algorithms."""
@inline loop_cursor(::Any, ::Val{Pausable} = Val(false)) where {Pausable} = NoLoopCursor()

"""Build a loop cursor from an executable wrapper by using its plan."""
@inline loop_cursor(la::LoopAlgorithm, pausable::Val{Pausable} = Val(false)) where {Pausable} =
    loop_cursor(getplan(la), pausable)

"""Build a loop cursor from a finalized wrapper by using its inner loop."""
@inline loop_cursor(fa::FinalizedAlgorithm, pausable::Val{Pausable} = Val(false)) where {Pausable} =
    loop_cursor(inneralgorithm(fa), pausable)

"""Build a per-run loop cursor for a composite plan.

The generated body mirrors the exact recursive child shape of the plan, so a
run allocates only the small mutable cursors or resume arrays that the plan
requires.
"""
@generated function loop_cursor(plan::P, ::Val{Pausable} = Val(false)) where {P<:CompositeAlgorithm, Pausable}
    children = Expr(:tuple, (:(@inline loop_cursor(getfield(@inline(getalgos(plan)), $i), Val($Pausable))) for i in 1:numalgos(P))...)
    return quote
        CompositeLoopCursor(Ref(1), $children)
    end
end

"""Build a per-run loop cursor for a routine plan."""
@generated function loop_cursor(plan::P, ::Val{Pausable} = Val(false)) where {P<:Routine, Pausable}
    children = Expr(:tuple, (:(@inline loop_cursor(getfield(@inline(getalgos(plan)), $i), Val($Pausable))) for i in 1:numalgos(P))...)
    if Pausable
        n = numalgos(P)
        return quote
            PausableRoutineCursor(MVector{$n, Int}(ones(Int, $n)), $children)
        end
    end
    return quote
        DirectRoutineCursor($children)
    end
end

"""Return the current resume point for a pausable routine child."""
@inline get_resume_point(cursor::PausableRoutineCursor, idx::Int) = getfield(cursor, :resume_idxs)[idx]

"""Direct routine runs never resume, so every child starts at its first repeat."""
@inline get_resume_point(::DirectRoutineCursor, idx::Int) = 1

"""Update the resume point for a pausable routine child."""
@inline set_resume_point!(cursor::PausableRoutineCursor, idx::Int, loopidx::Int) =
    (getfield(cursor, :resume_idxs)[idx] = loopidx)

"""Non-pausable routine runs do not retain resume points."""
@inline set_resume_point!(::DirectRoutineCursor, idx::Int, loopidx::Int) = nothing

"""Return the mutable resume array for inspection-oriented internal callers."""
@inline resume_idxs(cursor::PausableRoutineCursor) = getfield(cursor, :resume_idxs)

"""Direct routine runs intentionally have no resume storage."""
@inline resume_idxs(::DirectRoutineCursor) = ()
