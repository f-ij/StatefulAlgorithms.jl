#=
What every process constructor shares: turning what the user passes into a plan (`parse_plan`) and into a lifetime
(`parse_lifetime`, `default_lifetime`), and resolving the inputs and overrides given to a constructor against the
plan's registry (`resolve_process_inputs_overrides`).
=#

"""The plan a process runs for `func`: a plan (or plan type) as it is, anything else wrapped in a `CompositeAlgorithm`."""
@inline parse_plan(func::F) where {F} = (func isa LoopSpec || func isa Type{<:LoopSpec}) ? func : CompositeAlgorithm(func)

# Deprecated: the old name, kept only because InteractiveIsing still calls it (`Windows/Panels/PanelUtils.jl`,
# `Sim/Process.jl`). Remove once it no longer does.
function normalize_process_algo(func::F) where {F}
    @warn "`StatefulAlgorithms.normalize_process_algo` is deprecated and internal: use `parse_plan`, or better no internal API at all." maxlog = 1
    return parse_plan(func)
end

"""
    parse_lifetime(lifetime, repeats) -> Union{Nothing, Lifetime}

The lifetime a call's `lifetime` keyword (a `Lifetime`) or repeat count `repeats` (`Inf` is `Indefinite()`) gives. At
most one may be given; `nothing` when neither is, so the caller keeps its own default (`default_lifetime` for a new
`Process`). Used by every process constructor, `run(ip)`, `run(plan, context)` and the manager's launches.
"""
function parse_lifetime(lifetime::L, repeats::R) where {L, R}
    isnothing(lifetime) || isnothing(repeats) || throw(ArgumentError("Pass only one of `lifetime` or `repeats`."))
    if !isnothing(lifetime)
        lifetime isa Lifetime || throw(ArgumentError("`lifetime` takes a `Lifetime` (`Repeat(n)`, `Until(...)`, ...), got `$lifetime`; pass a repeat count as `repeats = n`."))
        return lifetime
    end
    isnothing(repeats) && return nothing
    repeats isa Integer && return Repeat(repeats)
    repeats isa AbstractFloat && isinf(repeats) && return Indefinite()
    throw(ArgumentError("`repeats` takes a whole number or `Inf`, got `$repeats`."))
end

"""
    _reject_run_lifetime(kwargs)

Throws when a `run` of a `Process` or `TimedProcess` is given `repeats` or `lifetime`: their runs use the process's
lifetime, set with `setlifetime!`.
"""
function _reject_run_lifetime(kwargs::K) where {K}
    (haskey(kwargs, :repeats) || haskey(kwargs, :lifetime)) &&
        throw(ArgumentError("`run` on a Process or TimedProcess takes no `repeats` or `lifetime`: set the lifetime with `setlifetime!(p, lt)` before the run."))
    return nothing
end

"""The lifetime of a new `Process` given none: one repeat for a `Routine` (a fixed sequence), otherwise until it is closed."""
function default_lifetime(plan::P) where {P}
    inner = plan isa LoopAlgorithm ? getplan(plan) : plan
    return (inner isa Routine || inner isa Type{<:Routine}) ? Repeat(1) : Indefinite()
end

function resolve_process_inputs_overrides(func, inputs_overrides)
    inputs_overrides isa Tuple || throw(ArgumentError("`resolve_process_inputs_overrides` expects inputs/overrides as a tuple."))
    isempty(inputs_overrides) && return (), ()

    if func isa Type{<:AbstractLoopAlgorithm}
        throw(ArgumentError("`resolve_process_inputs_overrides` requires an instantiated, resolved loop algorithm when inputs or overrides are present."))
    elseif !(func isa AbstractLoopAlgorithm)
        throw(ArgumentError("`resolve_process_inputs_overrides` requires a resolved loop algorithm when inputs or overrides are present."))
    end

    isresolved(func) || throw(ArgumentError("`resolve_process_inputs_overrides` requires a resolved loop algorithm when inputs or overrides are present. Call `resolve` before resolving inputs."))
    reg = getregistry(func)

    inputs = @inline filter_by_type(InitArgs, inputs_overrides)
    overrides = @inline filter_by_type(Override, inputs_overrides)

    named_inputs = resolve(reg, inputs)
    named_overrides = resolve(reg, overrides)

    return named_inputs, named_overrides
end
