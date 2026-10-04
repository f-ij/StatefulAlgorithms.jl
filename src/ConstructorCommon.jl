"""
Throw `ErrorException(string(parts...))`, or `AssertionError` from `construction_assert_error`.

Construction code uses these instead of `error("... \$(value) ...")` and `@assert cond "... \$(value)"`: Julia compiles
the message (`string` and `show` of the value) even when the error never fires, and compiles it again for every new
value type, such as every `Unique` handle. Here the message is only built when the error is thrown.
"""
@noinline Base.@nospecializeinfer construction_error(@nospecialize(parts...)) = error(parts...)
@noinline Base.@nospecializeinfer construction_assert_error(@nospecialize(parts...)) = throw(AssertionError(string(parts...)))

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
