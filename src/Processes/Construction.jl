#=
What every process constructor shares: the plan a function becomes (`normalize_process_algo`), the lifetime a
`repeats`/`lifetime` argument becomes (`normalize_lifetime_arguments`, `normalize_process_lifetime`), and the inputs and overrides given to a
constructor resolved against the plan's registry (`resolve_process_inputs_overrides`).
=#

@inline normalize_process_algo(func::F) where {F<:LoopSpec} = func
@inline normalize_process_algo(func::Type{F}) where {F<:LoopSpec} = func
@inline normalize_process_algo(func::F) where {F} = CompositeAlgorithm(func)

@inline normalize_process_lifetime(func, lifetime::Integer) = Repeat(lifetime)
@inline _is_routine_plan(func) = func isa Routine || func isa Type{<:Routine}
@inline _is_routine_plan(func::LoopAlgorithm) = _is_routine_plan(getplan(func))
@inline function normalize_process_lifetime(@nospecialize(func), ::Nothing)
    if _is_routine_plan(func)
        return Repeat(1)
    else
        return Indefinite()
    end
end
@inline normalize_process_lifetime(func, lifetime::LT) where {LT<:Lifetime} = lifetime
normalize_process_lifetime(func, lifetime) =
    construction_error("Unsupported process lifetime `", lifetime, "` for `", func, "`.")

"""
    normalize_lifetime_arguments(algo, positional, lifetime, repeats, repeat) -> Union{Nothing, Lifetime}

The lifetime the lifetime arguments of a process call give: a positional lifetime (`run(p, lt)`) or the `lifetime`
keyword, which take a `Lifetime` (a number there is an error), or a repeat count (`repeats`, `repeat`; `Inf` is
`Indefinite()`). At most one may be given. `nothing` when none is, so the caller picks its default. Used by the `Process` and `InlineProcess` constructors and runs, and by the
manager's launches.
"""
@inline function normalize_lifetime_arguments(algo::A, positional::P, lifetime::L, repeats::R, repeat::RR) where {A, P, L, R, RR}
    count(!isnothing, (positional, lifetime, repeats, repeat)) > 1 &&
        throw(ArgumentError("Pass only one of a positional lifetime, `lifetime`, `repeats` or `repeat`."))
    (positional isa Union{Nothing, Lifetime} && lifetime isa Union{Nothing, Lifetime}) ||
        throw(ArgumentError("`lifetime` takes a `Lifetime` (`Repeat(n)`, `Until(...)`, ...); pass a repeat count as `repeats = n`."))
    value = something(positional, lifetime, repeats, repeat, Some(nothing))
    isnothing(value) && return nothing
    value isa AbstractFloat && isinf(value) && return Indefinite()
    return normalize_process_lifetime(algo, value)
end

@inline instantiate_process_algo(func::F) where {F<:LoopSpec} = func
@inline instantiate_process_algo(func::Type{F}) where {F<:LoopSpec} = func()

@inline resolve_process_inputs_overrides(func) = resolve_process_inputs_overrides(func, ())

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
