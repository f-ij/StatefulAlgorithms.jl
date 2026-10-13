#=
Legacy DSL: the macros as they worked before returns became plain values (see docs/src/user/migrating_dsl.md).
Deprecated, and removed in a later version. Everything here is in this folder; removing it is deleting the folder and
its `include`.

The differences from `@CompositeAlgorithm`, `@Routine` and `@StepAlgorithm`:
- `y = Algo()` binds the field `y` of what `Algo` returns, instead of the whole return value;
- a `@StepAlgorithm_legacy` step returns a named tuple whose names are written back where they live (its state, or the
  variable passed to it), instead of a return value and `@update`s.
=#
export @CompositeAlgorithm_legacy, @Routine_legacy, @StepAlgorithm_legacy

"""The DSL rules of the legacy macros: `y = Algo()` binds the returned field `y`."""
struct LegacyDSL <: DSLRules end

_composite_dsl_bind_returns!(::LegacyDSL, algos::Vector{Any}, specification::Vector{Any}, options::Vector{Any}, producers::Dict{Symbol, Any}, state_owners::Dict{Symbol, Any}, entity, owner, returns, outputs::Tuple{Vararg{Symbol}}, schedule) =
    _composite_dsl_bind_outputs!(options, producers, state_owners, owner, outputs)

"""
The legacy lifetime selector: a name the statement itself assigns reads the repeated algorithm's field of that name
(`count = @repeat Until(c, count) Counter`); any other name resolves as in `@Routine`.
"""
function _composite_dsl_var_selector(rules::LegacyDSL, producers::Dict{Symbol, Any}, current_owner, current_outputs::Tuple, name::Symbol)
    if name in current_outputs
        isnothing(current_owner) && error("Cannot use current output `$name` as a lifetime selector here.")
        return Var(_composite_dsl_var_owner(current_owner), name)
    end
    return invoke(_composite_dsl_var_selector, Tuple{DSLRules, Dict{Symbol, Any}, Any, Tuple, Symbol}, rules, producers, current_owner, current_outputs, name)
end

function _legacy_warn(name::Symbol, replacement::Symbol)
    @warn "`@$name` is deprecated and will be removed: move to `@$replacement` (see docs/src/user/migrating_dsl.md)." _id = name maxlog = 1
end

"""
    @CompositeAlgorithm_legacy begin ... end

Deprecated: `@CompositeAlgorithm` with the older rules (`y = Algo()` binds the returned field `y`). See
`docs/src/user/migrating_dsl.md` to move to `@CompositeAlgorithm`.
"""
macro CompositeAlgorithm_legacy(args...)
    _legacy_warn(:CompositeAlgorithm_legacy, :CompositeAlgorithm)
    parsed = _dsl_parse_loopalgorithm_macro_args(args, :CompositeAlgorithm)
    expanded = _dsl_expand_loopalgorithm(parsed.block, :CompositeAlgorithm, :every; print_constructor = parsed.print_constructor, rules = :(StatefulAlgorithms.LegacyDSL()))
    return _dsl_assign_header(expanded, parsed.name)
end

"""
    @Routine_legacy begin ... end

Deprecated: `@Routine` with the older rules (`y = Algo()` binds the returned field `y`). See
`docs/src/user/migrating_dsl.md` to move to `@Routine`.
"""
macro Routine_legacy(args...)
    _legacy_warn(:Routine_legacy, :Routine)
    parsed = _dsl_parse_loopalgorithm_macro_args(args, :Routine)
    expanded = _dsl_expand_loopalgorithm(parsed.block, :Routine, :repeat; print_constructor = parsed.print_constructor, rules = :(StatefulAlgorithms.LegacyDSL()))
    return _dsl_assign_header(expanded, parsed.name)
end

"""
    @StepAlgorithm_legacy function Name(...) ... end

Deprecated: `@StepAlgorithm` with the older rule that a step returns a named tuple whose names are written back where
they live. See `docs/src/user/migrating_dsl.md` to move to `@StepAlgorithm` with `@update`.
"""
macro StepAlgorithm_legacy(ex)
    _legacy_warn(:StepAlgorithm_legacy, :StepAlgorithm)
    return _step_algorithm_macro(ex; legacy = true)
end
