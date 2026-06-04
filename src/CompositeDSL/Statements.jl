"""Pick the most readable custom name for a DSL statement when no explicit alias is given."""
function _dsl_customname(ex, alias_name::Symbol)
    alias_name != Symbol() && return alias_name
    if ex isa Symbol
        return ex
    elseif ex isa Expr && ex.head == :call
        return _dsl_customname(ex.args[1], Symbol())
    elseif ex isa Expr && ex.head == :. && ex.args[end] isa QuoteNode
        return ex.args[end].value
    end
    return Symbol()
end

"""Return whether a schedule value is a lifetime constructor call supported by `@repeat`."""
function _dsl_lifetime_constructor_name(ex::Ex) where {Ex}
    if ex isa Symbol
        return ex
    elseif ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        return ex.args[2].value
    end
    return nothing
end

"""Rewrite one DSL variable selector into a runtime `Var` selector expression."""
function _dsl_repeat_lifetime_selector_expr(selector::S) where {S}
    if selector isa Symbol
        return :(StatefulAlgorithms._composite_dsl_var_selector(_dsl_producers, _dsl_owner, _dsl_outputs, $(QuoteNode(selector))))
    end
    return esc(selector)
end

"""Lower a `@repeat` schedule value, resolving DSL variable selectors in lifetimes."""
function _dsl_repeat_schedule_expr(schedule_value::SV) where {SV}
    if schedule_value isa Expr && schedule_value.head == :call
        constructor = _dsl_lifetime_constructor_name(schedule_value.args[1])
        if constructor == :Repeat
            length(schedule_value.args) == 2 || error("Repeat schedules must be written as `Repeat(n)`.")
            return :(StatefulAlgorithms.Repeat($(esc(schedule_value.args[2]))))
        elseif constructor == :Indefinite
            length(schedule_value.args) == 1 || error("Indefinite schedules must be written as `Indefinite()`.")
            return :(StatefulAlgorithms.Indefinite())
        elseif constructor == :Until
            length(schedule_value.args) == 3 || error("Until schedules must be written as `Until(condition, selector)`.")
            return :(StatefulAlgorithms.Until($(esc(schedule_value.args[2])), $(_dsl_repeat_lifetime_selector_expr(schedule_value.args[3]))))
        elseif constructor == :RepeatOrUntil
            length(schedule_value.args) == 4 || error("RepeatOrUntil schedules must be written as `RepeatOrUntil(condition, n, selector)`.")
            return :(StatefulAlgorithms.RepeatOrUntil($(esc(schedule_value.args[2])), $(esc(schedule_value.args[3])), $(_dsl_repeat_lifetime_selector_expr(schedule_value.args[4]))))
        elseif constructor == :AtLeast
            length(schedule_value.args) == 4 || error("AtLeast schedules must be written as `AtLeast(condition, n, selector)`.")
            return :(StatefulAlgorithms.AtLeast($(esc(schedule_value.args[2])), $(esc(schedule_value.args[3])), $(_dsl_repeat_lifetime_selector_expr(schedule_value.args[4]))))
        elseif constructor == :AtLeastAtMost
            length(schedule_value.args) == 5 || error("AtLeastAtMost schedules must be written as `AtLeastAtMost(condition, min, max, selector)`.")
            return :(StatefulAlgorithms.AtLeastAtMost($(esc(schedule_value.args[2])), $(esc(schedule_value.args[3])), $(esc(schedule_value.args[4])), $(_dsl_repeat_lifetime_selector_expr(schedule_value.args[5]))))
        end
    end
    return :(StatefulAlgorithms.Repeat(Int($(esc(schedule_value)))))
end

"""Validate schedule usage and turn it into the constructor specification entry."""
function _dsl_schedule_expr(schedule_kind::Symbol, schedule_value, expected_schedule::Symbol, owner_name::Symbol)
    if schedule_kind == :default
        return expected_schedule == :repeat ? :(StatefulAlgorithms.Repeat(1)) : :(1)
    elseif expected_schedule == :none
        got = schedule_kind == :every ? "@interval" : "@repeat"
        error("Use plain entries inside `@$(owner_name) ... begin ... end`, not `$got`.")
    elseif schedule_kind == expected_schedule
        return expected_schedule == :repeat ? _dsl_repeat_schedule_expr(schedule_value) : :(Int($(esc(schedule_value))))
    else
        expected = expected_schedule == :every ? "@interval" : "@repeat"
        got = schedule_kind == :every ? "@interval" : "@repeat"
        error("Use `$expected` inside `@$owner_name`, not `$got`.")
    end
end

"""Emit either `algo` or `:alias => algo` for the target constructor call."""
function _dsl_algorithm_entry_expr(alias_name::Symbol, entity_expr::E = :(_dsl_entity)) where {E}
    return :(StatefulAlgorithms._composite_dsl_entry($entity_expr, $(QuoteNode(alias_name))))
end

"""Wrap an algorithm constructor entry in a parser option when conditionally included."""
function _dsl_maybe_conditional_entry_expr(entry_expr, include_condition)
    isnothing(include_condition) && return entry_expr
    return :(StatefulAlgorithms.IfWrapped($entry_expr, $include_condition))
end

"""Guard constructor-side metadata for conditionally included entries."""
function _dsl_maybe_guard_metadata_expr(expr, include_condition)
    isnothing(include_condition) && return expr
    return quote
        if $include_condition
            $expr
        end
    end
end

"""Parse `@route source.field => target.field` as a top-level plan route."""
function _dsl_build_global_route_statement(stmt, alias_map, context_map; include_condition = nothing)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@route") || return nothing
    length(stmt.args) >= 3 || error("@route expects `source.field => target.field`.")
    route_expr = stmt.args[3]
    route_expr isa Expr && route_expr.head == :call && route_expr.args[1] == :(=>) && length(route_expr.args) == 3 ||
        error("@route expects `source.field => target.field`.")

    source = _dsl_parse_owned_route_expr(alias_map, context_map, route_expr.args[2])
    target = _dsl_parse_owned_route_expr(alias_map, context_map, route_expr.args[3])
    isnothing(source) && error("@route source must be an owned field reference like `source.value` or `c1.inner.value`.")
    isnothing(target) && error("@route target must be an owned field reference like `sink.value`.")

    transform = nothing
    reverse_transform = nothing
    for arg in stmt.args[4:end]
        if arg isa Expr && arg.head == :(=) && arg.args[1] == :transform
            isnothing(transform) || error("@route received duplicate `transform` arguments.")
            transform = arg.args[2]
        elseif arg isa Expr && arg.head == :(=) && arg.args[1] == :reverse_transform
            isnothing(reverse_transform) || error("@route received duplicate `reverse_transform` arguments.")
            reverse_transform = arg.args[2]
        else
            error("Unsupported @route argument `$arg`. Use `@route source.x => target.y`, optionally with `transform = f` and `reverse_transform = g`.")
        end
    end

    route = if isnothing(transform) && isnothing(reverse_transform)
        :(StatefulAlgorithms.Route($(esc(source.owner)) => $(esc(target.owner)), $(QuoteNode(source.source)) => $(QuoteNode(target.source))))
    elseif isnothing(reverse_transform)
        :(StatefulAlgorithms.Route($(esc(source.owner)) => $(esc(target.owner)), $(QuoteNode(source.source)) => $(QuoteNode(target.source)); transform = $(esc(transform))))
    elseif isnothing(transform)
        :(StatefulAlgorithms.Route($(esc(source.owner)) => $(esc(target.owner)), $(QuoteNode(source.source)) => $(QuoteNode(target.source)); reverse_transform = $(esc(reverse_transform))))
    else
        :(StatefulAlgorithms.Route($(esc(source.owner)) => $(esc(target.owner)), $(QuoteNode(source.source)) => $(QuoteNode(target.source)); transform = $(esc(transform)), reverse_transform = $(esc(reverse_transform))))
    end
    return _dsl_maybe_guard_metadata_expr(:(push!(_dsl_options, $route)), include_condition)
end

"""
Emit the share/route owner expression matching the eventual constructor entry.

When the DSL already knows a stable alias/key, use that keyed wrapper directly so
later composition/renaming can update the reference without relying on raw-value
matching. Otherwise fall back to the raw entity and let constructor-time naming
resolve it later.
"""
function _dsl_share_endpoint_expr(alias_name::Symbol, entity_expr::E = :(_dsl_entity)) where {E}
    _dsl_known_owner_expr(entity_expr, alias_name)
end

"""Return an expression that prefixes nested state warning paths with one context alias."""
function _dsl_contextual_entity_expr(context_alias::Symbol)
    context_alias == Symbol() && return :(_dsl_resolved.entity)
    return :(StatefulAlgorithms._composite_dsl_prefix_state_diagnostic_paths(_dsl_resolved.entity, $(QuoteNode(context_alias))))
end

"""Remember the pushed algorithm index for a `@context` alias."""
function _dsl_register_context_index_expr(context_alias::Symbol)
    context_alias == Symbol() && return nothing
    return :(_dsl_context_indices[$(QuoteNode(context_alias))] = length(_dsl_algos))
end

"""Parse a current-block or child inline-state field selector.

Selectors are used by `@bind` and `@merge`. A plain symbol such as `buffers`
selects the current block's inline state. A dotted expression such as
`f.buffers` or `f._state.buffers` selects the inline state of the `@context f`
entry. The returned `scope` is `:local` or `:context`; `display` preserves the
user-facing selector for diagnostics.
"""
function _dsl_parse_state_field_selector(context_map::CM, ex::Ex) where {CM<:Dict, Ex}
    if ex isa Symbol
        return (; scope = :local, context_alias = Symbol(), field = ex, display = string(ex))
    elseif ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        field = ex.args[2].value
        field isa Symbol || return nothing
        base = ex.args[1]
        if base isa Symbol && haskey(context_map, base)
            return (; scope = :context, context_alias = base, field, display = string(base, ".", field))
        elseif base isa Expr && base.head == :. && length(base.args) == 2 && base.args[2] isa QuoteNode && base.args[2].value == :_state
            context_alias = base.args[1]
            if context_alias isa Symbol && haskey(context_map, context_alias)
                return (; scope = :context, context_alias, field, display = string(context_alias, "._state.", field))
            end
        end
    end
    return nothing
end

"""Return user payload arguments from a DSL-only macro call."""
function _dsl_macro_payload_args(stmt::S) where {S}
    args = [stmt.args[i] for i in 3:length(stmt.args) if !(stmt.args[i] isa LineNumberNode)]
    if length(args) == 1 && args[1] isa Expr && args[1].head == :tuple
        return Any[args[1].args...]
    end
    return args
end

"""Parse `@bind source => child.field` as an explicit state-sharing approval."""
function _dsl_build_state_bind_statement(stmt::S, context_map::CM) where {S, CM<:Dict}
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@bind") || return nothing
    args = _dsl_macro_payload_args(stmt)
    length(args) == 1 || error("@bind expects one mapping like `@bind buffers => f.buffers`.")
    mapping = only(args)
    mapping isa Expr && mapping.head == :call && mapping.args[1] == :(=>) && length(mapping.args) == 3 ||
        error("@bind expects one mapping like `@bind buffers => f.buffers`.")

    source = _dsl_parse_state_field_selector(context_map, mapping.args[2])
    target = _dsl_parse_state_field_selector(context_map, mapping.args[3])
    isnothing(source) && error("@bind source must be a state field like `buffers`.")
    isnothing(target) && error("@bind target must be a child state field like `f.buffers`.")
    source.scope == :local || error("@bind source must be a current-block state field. Got `$(source.display)`.")
    target.scope == :context || error("@bind target must be a child state field. Got `$(target.display)`.")
    source.field == target.field || error("@bind currently requires matching field names. Got `$(source.display)` and `$(target.display)`.")

    return quote
        StatefulAlgorithms._composite_dsl_mark_local_shared_state_field!(_dsl_states, $(QuoteNode(source.field)))
        StatefulAlgorithms._composite_dsl_mark_context_shared_state_field!(_dsl_algos, _dsl_context_indices, $(QuoteNode(target.context_alias)), $(QuoteNode(target.field)))
    end
end

"""Parse `@merge child.field, other_child.field` as an explicit peer state merge approval."""
function _dsl_build_state_merge_statement(stmt::S, context_map::CM) where {S, CM<:Dict}
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@merge") || return nothing
    args = _dsl_macro_payload_args(stmt)
    length(args) >= 2 || error("@merge expects at least two child state fields, e.g. `@merge f.buffers, n.buffers`.")
    selectors = map(arg -> _dsl_parse_state_field_selector(context_map, arg), args)
    any(isnothing, selectors) && error("@merge only accepts child state fields like `f.buffers` or `f._state.buffers`.")
    all(selector -> selector.scope == :context, selectors) || error("@merge only accepts child state fields; use `@bind` for current-block state.")
    field = first(selectors).field
    all(selector -> selector.field == field, selectors) || error("@merge currently requires matching field names. Got `$(join(getproperty.(selectors, :display), ", "))`.")

    shared_field_marks = map(selectors) do selector
        :(StatefulAlgorithms._composite_dsl_mark_context_shared_state_field!(_dsl_algos, _dsl_context_indices, $(QuoteNode(selector.context_alias)), $(QuoteNode(selector.field))))
    end
    return quote
        $(shared_field_marks...)
    end
end

"""Return whether a RHS expression should stay on the normal invocation parser."""
function _dsl_is_invocation_like_rhs(alias_map, known_outputs::Set{Symbol}, rhs)
    rhs isa QuoteNode && return false
    rhs isa Symbol && return haskey(alias_map, rhs) || rhs in known_outputs
    rhs isa Expr || return false
    rhs.head == :call && return true
    rhs.head == :macrocall && return true
    return false
end

"""Parse `state_field = captured_value` into a small `ContextWrite` algorithm."""
function _dsl_parse_context_write_assignment(alias_map, context_map, outputs::Tuple, rhs, known_outputs::Set{Symbol}, state_outputs::Set{Symbol})
    length(outputs) == 1 || return nothing
    output = only(outputs)
    output in state_outputs || return nothing

    schedule_kind, schedule_value, inner = _dsl_parse_schedule(rhs)
    _dsl_is_invocation_like_rhs(alias_map, known_outputs, inner) && return nothing

    value_spec, value_input = _dsl_parse_function_positional_arg(alias_map, context_map, inner, known_outputs, 1)
    inputs = isnothing(value_input) ? () : (_dsl_context_write_value_input(value_input),)
    spec_expr = if isnothing(value_input)
        :(StatefulAlgorithms.ContextWrite($(QuoteNode(output)), $(_dsl_context_write_value_expr(value_spec))))
    else
        :(StatefulAlgorithms.ContextWrite($(QuoteNode(output))))
    end
    return (
        kind = :entity,
        spec_expr,
        alias_name = Symbol(),
        positional_specs = (),
        routed_positional_inputs = (),
        inputs,
        shares = (),
        keyword_specs = (),
        schedule_kind,
        schedule_value,
    )
end

"""Lower `buffer[idx...] = value` to a normal `setindex!(buffer, value, idx...)` call."""
function _dsl_indexed_assignment_call(lhs, rhs)
    lhs isa Expr && lhs.head == :ref && !isempty(lhs.args) || return nothing
    return Expr(:call, :setindex!, lhs.args[1], rhs, lhs.args[2:end]...)
end

"""Lower `buffer .= value` and `buffer[idx...] .= value` to broadcast mutation calls."""
function _dsl_broadcast_assignment_call(lhs, rhs)
    if lhs isa Expr && lhs.head == :ref && !isempty(lhs.args)
        return Expr(:call, :(StatefulAlgorithms.context_broadcast_index!), lhs.args[1], rhs, lhs.args[2:end]...)
    end
    return Expr(:call, :(StatefulAlgorithms.context_broadcast!), lhs, rhs)
end

function _dsl_context_write_value_expr(spec)
    if spec.kind == :literal_symbol
        return QuoteNode(spec.value)
    elseif spec.kind == :captured
        return spec.value
    end
    error("ContextWrite captured values only support literal or captured positional specs. Got `$(spec.kind)`.")
end

function _dsl_context_write_value_input(input)
    if input.kind == :simple
        return (; kind = :simple, source = input.source, destination = :value)
    elseif input.kind == :context_simple
        return (; kind = :context_simple, owner = input.owner, source = input.source, destination = :value)
    elseif input.kind == :simple_transform
        return (; kind = :simple_transform, source = input.source, destination = :value, transform_expr = input.transform_expr)
    elseif input.kind == :context_transform
        return (; kind = :context_transform, owner = input.owner, source = input.source, destination = :value, transform_expr = input.transform_expr)
    end
    error("Unsupported ContextWrite value input kind `$(input.kind)`.")
end

function _dsl_parse_owned_write_target(alias_map, context_map, lhs)
    if lhs isa Expr && lhs.head == :. && length(lhs.args) == 2 && lhs.args[2] isa QuoteNode
        source = lhs.args[2].value
        source isa Symbol || return nothing
        base = lhs.args[1]
        if base isa Symbol && haskey(alias_map, base)
            return (; owner = :(StatefulAlgorithms._composite_dsl_write_owner($(alias_map[base]), $(QuoteNode(base)))), source)
        end
    end
    return _dsl_parse_owned_route_expr(alias_map, context_map, lhs)
end

"""Build `owner.field = value` as a routed ContextWrite into `owner.field`."""
function _dsl_build_owned_write_statement(lhs, rhs, alias_map, context_map, known_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol; include_condition = nothing)
    owned_route = _dsl_parse_owned_write_target(alias_map, context_map, lhs)
    isnothing(owned_route) && return nothing

    schedule_kind, schedule_value, inner = _dsl_parse_schedule(rhs)
    schedule_expr = _dsl_schedule_expr(schedule_kind, schedule_value, expected_schedule, owner_name)

    value_spec, value_input = _dsl_parse_function_positional_arg(alias_map, context_map, inner, known_outputs, 1)
    current_input = (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination = owned_route.source)
    inputs = if isnothing(value_input)
        (current_input,)
    else
        (current_input, _dsl_context_write_value_input(value_input))
    end
    inputs_expr = _dsl_inputs_expr(inputs)
    spec_expr = if isnothing(value_input)
        :(StatefulAlgorithms.ContextWrite($(QuoteNode(owned_route.source)), $(_dsl_context_write_value_expr(value_spec))))
    else
        :(StatefulAlgorithms.ContextWrite($(QuoteNode(owned_route.source))))
    end

    return quote
        local _dsl_outputs = ()
        local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_entity($(esc(spec_expr)), $inputs_expr, _dsl_outputs, Val{Symbol()}())
        local _dsl_owner = _dsl_resolved.entity
        push!(_dsl_algos, _dsl_resolved.entity)
        push!(_dsl_specification, $schedule_expr)
        $(_dsl_maybe_guard_metadata_expr(quote
            StatefulAlgorithms._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
        end, include_condition))
    end
end

"""
Build one executable DSL statement inside a composite or routine block.

Accepted top-level statements inside the block:
- `@state ...`
- `@alias ...`
- bare algorithm/state/function entries
- assignments like `x = ...` or `a, b = ...`
- scheduled entries via `@interval`, `@every`, or `@repeat`

`@finally` is root-only and handled by the surrounding block collector.
"""
function _dsl_build_statement(stmt, alias_map, context_map, known_outputs::Set{Symbol}, state_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol; include_condition = nothing, context_alias::Symbol = Symbol())
    if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@input")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@alias")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@context")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@bind")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@merge")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@finally")
        error("@finally is root-only and must appear as a top-level DSL statement.")
    end

    global_route = _dsl_build_global_route_statement(stmt, alias_map, context_map; include_condition)
    isnothing(global_route) || return global_route

    outputs = ()
    rhs = stmt
    if stmt isa Expr && stmt.head == :(.=)
        rhs = _dsl_broadcast_assignment_call(stmt.args[1], stmt.args[2])
    elseif stmt isa Expr && stmt.head == :(=)
        lhs = stmt.args[1]
        rhs = stmt.args[2]
        indexed_call = _dsl_indexed_assignment_call(lhs, rhs)
        if !isnothing(indexed_call)
            rhs = indexed_call
        else
            owned_write = _dsl_build_owned_write_statement(lhs, rhs, alias_map, context_map, known_outputs, expected_schedule, owner_name; include_condition)
            !isnothing(owned_write) && return owned_write
            outputs = _dsl_parse_output_symbols(lhs)
        end
    end

    owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, rhs)
    if !isnothing(owned_route)
        length(outputs) == 1 || error("Owned field references like `alias.field` can only bind to one output symbol, e.g. `state = dynamics.state`.")
        output = only(outputs)
        output == owned_route.source || error("Owned field aliasing currently requires the output name to match the field name. Use `$(owned_route.source) = ...` for `$(repr(rhs))`.")
        metadata_expr = quote
            local _dsl_output = $(QuoteNode(output))
            local _dsl_owner = $(esc(owned_route.owner))
            if haskey(_dsl_state_owners, _dsl_output)
                StatefulAlgorithms._composite_dsl_push_local_option!(
                    _dsl_options,
                    _dsl_owner,
                    StatefulAlgorithms.Route(_dsl_owner => _dsl_state_owners[_dsl_output], _dsl_output => _dsl_output),
                )
                _dsl_producers[_dsl_output] = _dsl_state_owners[_dsl_output]
            else
                _dsl_producers[_dsl_output] = _dsl_owner
            end
        end
        return _dsl_maybe_guard_metadata_expr(metadata_expr, include_condition)
    end

    context_write = _dsl_parse_context_write_assignment(alias_map, context_map, outputs, rhs, known_outputs, state_outputs)
    parsed = isnothing(context_write) ? _dsl_parse_invocation(alias_map, context_map, rhs, known_outputs) : context_write
    outputs_expr = Expr(:tuple, [QuoteNode(sym) for sym in outputs]...)
    schedule_expr = _dsl_schedule_expr(parsed.schedule_kind, parsed.schedule_value, expected_schedule, owner_name)
    entity_expr = _dsl_contextual_entity_expr(context_alias)
    context_index_expr = _dsl_register_context_index_expr(context_alias)

    if parsed.kind == :entity
        customname = _dsl_customname(parsed.spec_expr, parsed.alias_name)
        algo_entry_expr = _dsl_maybe_conditional_entry_expr(_dsl_algorithm_entry_expr(parsed.alias_name), include_condition)
        share_target_expr = _dsl_share_endpoint_expr(parsed.alias_name)
        inputs_expr = _dsl_inputs_expr(parsed.inputs)
        metadata_expr = quote
            $(map(parsed.shares) do share_source
                :(StatefulAlgorithms._composite_dsl_push_local_option!(_dsl_options, _dsl_owner, StatefulAlgorithms.Share($(share_source), _dsl_owner)))
            end...)
            StatefulAlgorithms._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
            StatefulAlgorithms._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
        end
        return quote
            local _dsl_outputs = $outputs_expr
            # Resolve the user-facing DSL entity into a normal algorithm/state
            # object plus the routed input metadata the builder needs.
            local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_entity($(esc(parsed.spec_expr)), $inputs_expr, _dsl_outputs, Val{$(QuoteNode(customname))}())
            local _dsl_entity = $entity_expr
            local _dsl_owner = $share_target_expr
            if _dsl_resolved isa StatefulAlgorithms._CompositeDSLResolved{:state}
                # Inline states are stored separately and claim ownership of
                # their outputs immediately.
                $(_dsl_maybe_guard_metadata_expr(quote
                    push!(_dsl_states, _dsl_entity)
                    StatefulAlgorithms._composite_dsl_register_outputs!(_dsl_producers, _dsl_owner, _dsl_outputs)
                end, include_condition))
            else
                # Algorithms are appended to the constructor argument list and
                # then wired into the routing tables.
                push!(_dsl_algos, $algo_entry_expr)
                push!(_dsl_specification, $schedule_expr)
                $context_index_expr
                $(_dsl_maybe_guard_metadata_expr(metadata_expr, include_condition))
            end
        end
    end

    if parsed.kind == :resolved_expr
        algo_entry_expr = _dsl_maybe_conditional_entry_expr(_dsl_algorithm_entry_expr(parsed.alias_name), include_condition)
        owner_expr = _dsl_share_endpoint_expr(parsed.alias_name)
        metadata_expr = quote
            StatefulAlgorithms._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
            StatefulAlgorithms._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
        end
        return quote
            local _dsl_outputs = $outputs_expr
            # Repeated inner blocks already expand to one resolved entity, so the
            # outer builder only has to wire and register them.
            local _dsl_resolved = $(parsed.resolved_expr)
            local _dsl_entity = $entity_expr
            local _dsl_owner = $owner_expr
            push!(_dsl_algos, $algo_entry_expr)
            push!(_dsl_specification, $schedule_expr)
            $context_index_expr
            $(_dsl_maybe_guard_metadata_expr(metadata_expr, include_condition))
        end
    end

    positional_values_expr = _dsl_function_positional_args_expr(parsed.positional_specs)
    positional_display_expr = _dsl_function_positional_display_expr(parsed.positional_specs)
    routed_positional_inputs_expr = _dsl_inputs_expr(parsed.routed_positional_inputs)
    keyword_args_expr = _dsl_function_keyword_args_expr(parsed.keyword_specs)
    keyword_display_expr = _dsl_function_keyword_display_expr(parsed.keyword_specs)
    inputs_expr = _dsl_inputs_expr(parsed.inputs)
    customname = _dsl_customname(parsed.spec_expr, parsed.alias_name)
    algo_entry_expr = _dsl_maybe_conditional_entry_expr(_dsl_algorithm_entry_expr(parsed.alias_name), include_condition)
    share_target_expr = _dsl_share_endpoint_expr(parsed.alias_name)

    if parsed.kind == :keyword_call
        metadata_expr = quote
            $(map(parsed.shares) do share_source
                :(StatefulAlgorithms._composite_dsl_push_local_option!(_dsl_options, _dsl_owner, StatefulAlgorithms.Share($(share_source), _dsl_owner)))
            end...)
            StatefulAlgorithms._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
            StatefulAlgorithms._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
        end
        return quote
            local _dsl_outputs = $outputs_expr
            local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_keyword_call(
                $(esc(parsed.spec_expr)),
                $keyword_args_expr,
                $keyword_display_expr,
                $inputs_expr,
                _dsl_outputs,
                Val{$(QuoteNode(customname))}(),
            )
            local _dsl_entity = $entity_expr
            local _dsl_owner = $share_target_expr
            push!(_dsl_algos, $algo_entry_expr)
            push!(_dsl_specification, $schedule_expr)
            $context_index_expr
            $(_dsl_maybe_guard_metadata_expr(metadata_expr, include_condition))
        end
    end

    metadata_expr = quote
        StatefulAlgorithms._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
        StatefulAlgorithms._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
    end
    return quote
        local _dsl_outputs = $outputs_expr
        # Function-call syntax stays on a dedicated path so we can recover
        # positional inputs and keyword captures for `FuncWrapper`.
        local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_call(
            $(esc(parsed.spec_expr)),
            $keyword_args_expr,
            $positional_values_expr,
            $positional_display_expr,
            $keyword_display_expr,
            _dsl_outputs,
            $routed_positional_inputs_expr,
            $inputs_expr,
            Val{$(QuoteNode(customname))}(),
        )
        local _dsl_entity = $entity_expr
        local _dsl_owner = $share_target_expr
        push!(_dsl_algos, $algo_entry_expr)
        push!(_dsl_specification, $schedule_expr)
        $context_index_expr
        $(_dsl_maybe_guard_metadata_expr(metadata_expr, include_condition))
    end
end

"""Build a constructor-time conditional include block."""
function _dsl_build_include_if_statement(stmt, alias_map, context_map, known_outputs::Set{Symbol}, state_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol)
    condition_expr, include_body = _dsl_parse_include_if(stmt)
    statements = include_body isa Expr && include_body.head == :block ? include_body.args : Any[include_body]

    branch_alias_map = copy(alias_map)
    branch_context_map = copy(context_map)
    branch_known_outputs = copy(known_outputs)
    branch_state_outputs = copy(state_outputs)
    branch_exprs = Any[]
    current_line = nothing
    condition_sym = gensym(:include_if)

    for branch_stmt in statements
        if branch_stmt isa LineNumberNode
            current_line = branch_stmt
            continue
        end

        _dsl_reject_include_if_declarations(branch_stmt)

        if branch_stmt isa Expr && branch_stmt.head == :macrocall && branch_stmt.args[1] == Symbol("@context")
            context = _dsl_parse_context(branch_stmt)
            branch_alias_map[context.first] = context.second
            branch_context_map[context.first] = context.second
            step_expr = _dsl_build_statement(
                branch_stmt.args[3].args[2],
                branch_alias_map,
                branch_context_map,
                branch_known_outputs,
                branch_state_outputs,
                expected_schedule,
                owner_name;
                include_condition = condition_sym,
                context_alias = context.first,
            )
            if !isnothing(step_expr)
                step_expr = Base.remove_linenums!(step_expr)
                isnothing(current_line) || push!(branch_exprs, current_line)
                push!(branch_exprs, step_expr)
            end
            continue
        elseif branch_stmt isa Expr && branch_stmt.head == :macrocall && branch_stmt.args[1] == Symbol("@include_if")
            error("Nested `@include_if` blocks are not supported.")
        else
            step_expr = _dsl_build_statement(
                branch_stmt,
                branch_alias_map,
                branch_context_map,
                branch_known_outputs,
                branch_state_outputs,
                expected_schedule,
                owner_name;
                include_condition = condition_sym,
            )
        end

        if !isnothing(step_expr)
            step_expr = Base.remove_linenums!(step_expr)
            isnothing(current_line) || push!(branch_exprs, current_line)
            push!(branch_exprs, step_expr)
        end
        _dsl_known_outputs!(branch_known_outputs, branch_stmt)
    end

    return quote
        local $condition_sym = Bool($(esc(condition_expr)))
        $(branch_exprs...)
    end
end

"""
Walk a DSL block once and collect the state declarations plus executable statements.

This is shared by the top-level `@CompositeAlgorithm`/`@Routine` expansion and the
inner `@repeat n begin ... end` block expansion so they stay in sync.
"""
function _dsl_collect_block(
    statements,
    expected_schedule::Symbol,
    owner_name::Symbol;
    allow_final::Bool = false,
    initial_alias_map::Dict{Symbol, Any} = Dict{Symbol, Any}(),
    initial_context_map::Dict{Symbol, Any} = Dict{Symbol, Any}(),
)
    alias_map = copy(initial_alias_map)
    context_map = copy(initial_context_map)
    known_outputs = Set{Symbol}()
    step_exprs = Any[]
    state_fields = Any[]
    input_fields = Any[]
    state_outputs = Set{Symbol}()
    state_name = :_state
    final_expr = nothing
    current_line = nothing

    for stmt in statements
        if stmt isa LineNumberNode
            current_line = stmt
            continue
        end

        if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
            # States are collected first and emitted once for the whole block.
            state_name = _dsl_merge_state_statement!(state_fields, state_name, stmt)
            _, fields = _dsl_parse_state_statement(stmt)
            union!(state_outputs, getproperty.(fields, :name))
            _dsl_known_outputs!(known_outputs, stmt)
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@input")
            field = _dsl_parse_input_statement(stmt)
            push!(input_fields, field)
            push!(known_outputs, field.name)
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@alias")
            # Aliases only affect later statements, so store them and keep moving.
            alias = _dsl_parse_alias(stmt)
            alias_map[alias.first] = alias.second
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@finally")
            allow_final || error("@finally is only supported at the outer @CompositeAlgorithm or @Routine level.")
            isnothing(final_expr) || error("Only one @finally statement is supported per DSL block.")
            final_expr = _dsl_parse_finally(stmt)
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@context")
            context = _dsl_parse_context(stmt)
            alias_map[context.first] = context.second
            context_map[context.first] = context.second
            step_expr = _dsl_build_statement(stmt.args[3].args[2], alias_map, context_map, known_outputs, state_outputs, expected_schedule, owner_name; context_alias = context.first)
            if !isnothing(step_expr)
                step_expr = Base.remove_linenums!(step_expr)
                isnothing(current_line) || push!(step_exprs, current_line)
                push!(step_exprs, step_expr)
            end
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@bind")
            step_expr = _dsl_build_state_bind_statement(stmt, context_map)
            if !isnothing(step_expr)
                step_expr = Base.remove_linenums!(step_expr)
                isnothing(current_line) || push!(step_exprs, current_line)
                push!(step_exprs, step_expr)
            end
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@merge")
            step_expr = _dsl_build_state_merge_statement(stmt, context_map)
            if !isnothing(step_expr)
                step_expr = Base.remove_linenums!(step_expr)
                isnothing(current_line) || push!(step_exprs, current_line)
                push!(step_exprs, step_expr)
            end
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@include_if")
            step_expr = _dsl_build_include_if_statement(stmt, alias_map, context_map, known_outputs, state_outputs, expected_schedule, owner_name)
            if !isnothing(step_expr)
                step_expr = Base.remove_linenums!(step_expr)
                isnothing(current_line) || push!(step_exprs, current_line)
                push!(step_exprs, step_expr)
            end
            _dsl_known_outputs!(known_outputs, stmt)
            continue
        end

        step_expr = _dsl_build_statement(stmt, alias_map, context_map, known_outputs, state_outputs, expected_schedule, owner_name)
        if !isnothing(step_expr)
            step_expr = Base.remove_linenums!(step_expr)
            isnothing(current_line) || push!(step_exprs, current_line)
            push!(step_exprs, step_expr)
        end
        # Outputs become available to the statements that follow them.
        _dsl_known_outputs!(known_outputs, stmt)
    end

    return (; step_exprs, state_fields, input_fields, state_name, final_expr)
end
