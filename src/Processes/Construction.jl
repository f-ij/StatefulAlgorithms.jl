#=
What every process constructor shares: turning what the user passes into a plan (`parse_plan`) and into a lifetime
(`parse_lifetime`, `default_lifetime`), and resolving the inputs and overrides given to a constructor against the
plan's registry (`resolve_process_inputs_overrides`).
=#

"""The plan a process runs for `func`: a plan (or plan type) as it is, anything else wrapped in a `CompositeAlgorithm`."""
@inline parse_plan(func::F) where {F} = (func isa LoopSpec || func isa Type{<:LoopSpec}) ? func : CompositeAlgorithm(func)

"""
    parse_lifetime(positional, lifetime, repeats) -> Union{Nothing, Lifetime}

The lifetime a process call's arguments give: a positional lifetime (`run(p, lt)`) or the `lifetime` keyword, which
take a `Lifetime`, or a repeat count `repeats` (`Inf` is `Indefinite()`). At most one may be given; `nothing` when none
is, so the caller keeps its own default (`default_lifetime` for a new `Process`). Used by every process constructor and
run, `run(plan)` and the manager's launches.
"""
function parse_lifetime(positional::P, lifetime::L, repeats::R) where {P, L, R}
    count(!isnothing, (positional, lifetime, repeats)) > 1 &&
        throw(ArgumentError("Pass only one of a positional lifetime, `lifetime` or `repeats`."))
    given = something(positional, lifetime, Some(nothing))
    if !isnothing(given)
        given isa Lifetime || throw(ArgumentError("`lifetime` takes a `Lifetime` (`Repeat(n)`, `Until(...)`, ...), got `$given`; pass a repeat count as `repeats = n`."))
        return given
    end
    isnothing(repeats) && return nothing
    repeats isa Integer && return Repeat(repeats)
    repeats isa AbstractFloat && isinf(repeats) && return Indefinite()
    throw(ArgumentError("`repeats` takes a whole number or `Inf`, got `$repeats`."))
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

    inputs = @inline filter_by_type(Input, inputs_overrides)
    overrides = @inline filter_by_type(Override, inputs_overrides)

    named_inputs = resolve(reg, inputs)
    named_overrides = resolve(reg, overrides)

    return named_inputs, named_overrides
end
