#=
How a composite's schedule entries (Interval.jl next to this file) extend `compute_multiplier` (Hooks.jl next to this
file): a child with interval `n` runs once every `n` runs of its plan, so `1/n` times per run. A `RunIf` counts as its
interval; how often its condition holds is not known before the run.
=#

@inline compute_multiplier(i::I) where {I<:Interval} = 1 / getinterval(i)
@inline compute_multiplier(runif::R) where {R<:RunIf} = 1 / getinterval(runif)
