#=
How a composite's schedule entries (Interval.jl next to this file) extend the schedule-entry hooks (Hooks.jl next to
this file), and how a plan run directly answers `prepare_loop` (AbstractProcesses/Hooks.jl):
- `should_run_schedule`: an `Interval` runs on the ticks it divides (`divides`), a `RunIf` on those of its interval when
  its condition holds;
- `always_runs`: only `Interval(1)` without an offset; with an offset it skips the first `Offset` ticks;
- `compute_multiplier`: a child with interval `n` runs once every `n` runs of its plan, so `1/n` times per run. A `RunIf`
  counts as its interval; how often its condition holds is not known before the run.
- `prepare_loop`: a plan run directly runs as it is, in a new `InlineSession`, from its own context.
=#

"""
    prepare_loop(plan, inputs, lifetime, resume)

A plan run directly (`run(plan)`): a new `InlineSession` for the run (the loop needs a counter; nothing can pause or
close a direct run), the plan as it is, and the run starts from the plan's context (AbstractProcesses/Hooks.jl).
"""
@inline prepare_loop(plan::LA, inputs::I, lt::LT, resume::R) where {LA<:LoopSpec, I<:NamedTuple, LT, R<:Resuming} =
    InlineSession(), plan, (@inline LoopContext(plan, getpersistentcontext(plan), inputs, resume))

@inline should_run_schedule(interval::I, loopidx::Int, context::C) where {I<:Interval, C} = @inline divides(loopidx, interval)

@inline function should_run_schedule(runif::R, loopidx::Int, context::C) where {V, R<:RunIf{V}, C}
    if !(@inline divides(loopidx, runif))
        return false
    end
    if V === Tuple{}
        return @inline getcondition(runif)()
    end
    return @inline getcondition(runif)(getindex(context, getvars(runif)...))
end

@inline always_runs(::Type{I}) where {F, I<:Interval{1, F, 0}} = true

@inline compute_multiplier(i::I) where {I<:Interval} = 1 / getinterval(i)
@inline compute_multiplier(runif::R) where {R<:RunIf} = 1 / getinterval(runif)
