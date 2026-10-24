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

"""Rewrite a name in a lifetime condition into the `Var` selector of that block value (see `_composite_dsl_var_selector`)."""
function _dsl_repeat_lifetime_selector_expr(selector::S) where {S}
    if selector isa Symbol
        return :(StatefulAlgorithms._composite_dsl_var_selector(_dsl_rules, _dsl_producers, _dsl_owner, _dsl_outputs, $(QuoteNode(selector))))
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

"""
The code that binds a statement's left-hand side (see `_composite_dsl_bind_returns!`): what the DSL rules of the block
(`_dsl_rules`) say an algorithm's or a call's return gives the names on the left.
"""
_dsl_bind_returns_expr() = quote
    StatefulAlgorithms._composite_dsl_check_updates(_dsl_resolved.entity, _dsl_resolved.inputs, _dsl_producers, _dsl_state_owners, _dsl_mutable)
    StatefulAlgorithms._composite_dsl_bind_returns!(
        _dsl_rules, _dsl_algos, _dsl_specification, _dsl_options, _dsl_producers, _dsl_state_owners,
        _dsl_resolved.entity, _dsl_owner, _dsl_returns, _dsl_outputs, _dsl_schedule)
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
        :(StatefulAlgorithms.Route($(_dsl_input(source.owner)) => $(_dsl_input(target.owner)), $(QuoteNode(source.field)) => $(QuoteNode(target.field))))
    elseif isnothing(reverse_transform)
        :(StatefulAlgorithms.Route($(_dsl_input(source.owner)) => $(_dsl_input(target.owner)), $(QuoteNode(source.field)) => $(QuoteNode(target.field)); transform = $(esc(transform))))
    elseif isnothing(transform)
        :(StatefulAlgorithms.Route($(_dsl_input(source.owner)) => $(_dsl_input(target.owner)), $(QuoteNode(source.field)) => $(QuoteNode(target.field)); reverse_transform = $(esc(reverse_transform))))
    else
        :(StatefulAlgorithms.Route($(_dsl_input(source.owner)) => $(_dsl_input(target.owner)), $(QuoteNode(source.field)) => $(QuoteNode(target.field)); transform = $(esc(transform)), reverse_transform = $(esc(reverse_transform))))
    end
    return _dsl_maybe_guard_metadata_expr(:(push!(_dsl_options, $route)), include_condition)
end

"""Parse `@redirect source.field => target.field` as a root redirect option."""
function _dsl_build_redirect_statement(stmt, alias_map, context_map; include_condition = nothing)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@redirect") || return nothing
    length(stmt.args) == 3 || error("@redirect expects `source.field => target.field`.")
    redirect_expr = stmt.args[3]
    redirect_expr isa Expr && redirect_expr.head == :call && redirect_expr.args[1] == :(=>) && length(redirect_expr.args) == 3 ||
        error("@redirect expects `source.field => target.field`.")

    source = _dsl_parse_owned_route_expr(alias_map, context_map, redirect_expr.args[2])
    target = _dsl_parse_owned_route_expr(alias_map, context_map, redirect_expr.args[3])
    isnothing(source) && error("@redirect source must be an owned field reference like `source.value` or `c1.inner.value`.")
    isnothing(target) && error("@redirect target must be an owned field reference like `sink.value`.")

    redirect = :(StatefulAlgorithms.Redirect($(_dsl_input(source.owner)) => $(_dsl_input(target.owner)), $(QuoteNode(source.field)) => $(QuoteNode(target.field))))
    return _dsl_maybe_guard_metadata_expr(:(push!(_dsl_options, $redirect)), include_condition)
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

"""Return user payload arguments from a DSL-only macro call."""
function _dsl_macro_payload_args(stmt::S) where {S}
    args = [stmt.args[i] for i in 3:length(stmt.args) if !(stmt.args[i] isa LineNumberNode)]
    if length(args) == 1 && args[1] isa Expr && args[1].head == :tuple
        return Any[args[1].args...]
    end
    return args
end

"""
Parse one side of a `@bind` mapping into `(owner, field)` expressions: `x` is the current block's state field `x`;
`a.x` is field `x` of an alias, or of a nested block's state (`@context a = ...`), and deeper paths like `c.inner.x`
work as in routes.
"""
function _dsl_bind_endpoint(alias_map, context_map, ex)
    if ex isa Symbol
        return (; owner = :(StatefulAlgorithms._composite_dsl_state_owner(_dsl_state_owners, $(QuoteNode(ex)))), field = ex)
    elseif ex isa Expr && ex.head == :. && ex.args[1] isa Symbol && haskey(context_map, ex.args[1]) && ex.args[2] isa QuoteNode
        # `c.x` with `@context c = ...`: the state of the nested block that was added, not its expression evaluated again
        block = :(StatefulAlgorithms._composite_dsl_context_entity(_dsl_algos, _dsl_context_indices, $(QuoteNode(ex.args[1]))))
        return (; owner = :(StatefulAlgorithms._composite_dsl_block_state($block)), field = ex.args[2].value)
    end
    parsed = _dsl_parse_owned_route_expr(alias_map, context_map, ex)
    isnothing(parsed) && error("@bind endpoints are a state field like `x` or an owned field like `a.x`. Got `$ex`.")
    return (; owner = _dsl_input(parsed.owner), field = parsed.field)
end

"""Split `@bind a.x => b.y c.z => d.z [begin ... end]` into its mappings and the statements of its scope (or `nothing`)."""
function _dsl_split_bind(stmt)
    args = _dsl_macro_payload_args(stmt)
    scope = !isempty(args) && last(args) isa Expr && last(args).head == :block ? pop!(args).args : nothing
    isempty(args) && error("@bind expects mappings like `@bind x => c.x` or `@bind a.x => b.y c.z => d.z begin ... end`.")
    return args, scope
end

"""
An expression for the tuple of `(source_owner, :source_field, target_owner, :target_field)`, one per `@bind` mapping
`source => target` (in the bind's scope, `target` is `source`).
"""
function _dsl_bind_tuple(mappings, alias_map, context_map)
    binds = map(mappings) do mapping
        mapping isa Expr && mapping.head == :call && mapping.args[1] == :(=>) && length(mapping.args) == 3 ||
            error("@bind expects mappings like `source => target`. Got `$mapping`.")
        source = _dsl_bind_endpoint(alias_map, context_map, mapping.args[2])
        target = _dsl_bind_endpoint(alias_map, context_map, mapping.args[3])
        :(($(source.owner), $(QuoteNode(source.field)), $(target.owner), $(QuoteNode(target.field))))
    end
    return Expr(:tuple, binds...)
end

"""Parse `@merge c1, c2, ...`: the `@state`s of these nested blocks (`@context` aliases) become one state."""
function _dsl_build_state_merge_statement(stmt::S, context_map::CM) where {S, CM<:Dict}
    args = _dsl_macro_payload_args(stmt)
    length(args) >= 2 || error("@merge expects at least two nested blocks, e.g. `@merge f, n`.")
    for arg in args
        arg isa Symbol && haskey(context_map, arg) && continue
        error("@merge merges whole states of nested blocks named with `@context`, like `@merge f, n`. Got `$arg`. To make one field of one block another's, use `@redirect` or `@bind`.")
    end
    blocks = Expr(:tuple, (:(StatefulAlgorithms._composite_dsl_context_entity(_dsl_algos, _dsl_context_indices, $(QuoteNode(arg)))) for arg in args)...)
    return :(StatefulAlgorithms._composite_dsl_merge_states!(_dsl_states, $blocks))
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
        return (; kind = :simple, source_field = input.source_field, target_field = :value)
    elseif input.kind == :context_simple
        return (; kind = :context_simple, owner = input.owner, source_field = input.source_field, target_field = :value)
    elseif input.kind == :simple_transform
        return (; kind = :simple_transform, source_field = input.source_field, target_field = :value, transform_expr = input.transform_expr)
    elseif input.kind == :context_transform
        return (; kind = :context_transform, owner = input.owner, source_field = input.source_field, target_field = :value, transform_expr = input.transform_expr)
    end
    error("Unsupported ContextWrite value input kind `$(input.kind)`.")
end

function _dsl_parse_owned_write_target(alias_map, context_map, lhs)
    if lhs isa Expr && lhs.head == :. && length(lhs.args) == 2 && lhs.args[2] isa QuoteNode
        field = lhs.args[2].value
        field isa Symbol || return nothing
        base = lhs.args[1]
        if base isa Symbol && haskey(alias_map, base)
            return (; owner = :(StatefulAlgorithms._composite_dsl_write_owner($(alias_map[base]), $(QuoteNode(base)))), field)
        end
    end
    return _dsl_parse_owned_route_expr(alias_map, context_map, lhs)
end

"""Build `owner.field = value` as a routed ContextWrite into `owner.field`."""
function _dsl_build_owned_write_statement(lhs, rhs, alias_map, context_map, known_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol; include_condition = nothing)
    owned_route = _dsl_parse_owned_write_target(alias_map, context_map, lhs)
    isnothing(owned_route) && return nothing

    schedule_kind, schedule_value, inner = _dsl_parse_schedule(rhs)
    if inner isa Expr && inner.head == :call
        return _dsl_build_owned_call_write_statement(owned_route, rhs, alias_map, context_map, known_outputs, expected_schedule, owner_name; include_condition)
    end
    schedule_expr = _dsl_schedule_expr(schedule_kind, schedule_value, expected_schedule, owner_name)

    value_spec, value_input = _dsl_parse_function_positional_arg(alias_map, context_map, inner, known_outputs, 1)
    current_input = (; kind = :context_simple, owner = owned_route.owner, source_field = owned_route.field, target_field = owned_route.field)
    inputs = if isnothing(value_input)
        (current_input,)
    else
        (current_input, _dsl_context_write_value_input(value_input))
    end
    inputs_expr = _dsl_inputs_expr(inputs)
    spec_expr = if isnothing(value_input)
        :(StatefulAlgorithms.ContextWrite($(QuoteNode(owned_route.field)), $(_dsl_context_write_value_expr(value_spec))))
    else
        :(StatefulAlgorithms.ContextWrite($(QuoteNode(owned_route.field))))
    end

    return quote
        local _dsl_outputs = ()
        local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_entity($(_dsl_input(spec_expr)), $inputs_expr, _dsl_outputs, Val{Symbol()}())
        local _dsl_owner = _dsl_resolved.entity
        push!(_dsl_algos, _dsl_resolved.entity)
        push!(_dsl_specification, $schedule_expr)
        $(_dsl_maybe_guard_metadata_expr(quote
            StatefulAlgorithms._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
        end, include_condition))
    end
end

"""Inputs are read-only: an assignment to one (`x = f(...)` with `@input x`) is an error when the block is built."""
function _dsl_reject_input_assignment(stmt, input_fields, line)
    (stmt isa Expr && stmt.head == :(=)) || return nothing
    outputs = _dsl_try_parse_output_symbols(stmt.args[1])
    isnothing(outputs) && return nothing
    for field in input_fields
        field.name in outputs || continue
        at = isnothing(line) ? "" : " ($(line.file):$(line.line))"
        error("`$(stmt)` assigns `$(field.name)`, which is an `@input` of this block$at. Inputs are read-only; assign to another name.")
    end
    return nothing
end

"""
Build `owner.field = f(args...)`: the call runs every step (like `x = f(args...)`) and its return is written into
`owner.field`. The call's output gets a generated name, and a route from `owner.field` to that name is added to the
call: a return under a name its view can see is written back through the route.
"""
function _dsl_build_owned_call_write_statement(owned_route, rhs, alias_map, context_map, known_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol; include_condition = nothing)
    output = gensym(Symbol(:dsl_write_, owned_route.field))
    call_statement = _dsl_build_statement(:($output = $rhs), alias_map, context_map, known_outputs, Set{Symbol}(), expected_schedule, owner_name; include_condition)
    write_route = _dsl_inputs_expr(((; kind = :context_simple, owner = owned_route.owner, source_field = owned_route.field, target_field = output),))
    return quote
        $call_statement
        $(_dsl_maybe_guard_metadata_expr(quote
            StatefulAlgorithms._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, $write_route)
        end, include_condition))
    end
end

"""
The code that checks, when the block is built, that a statement `x = …` does not capture what has no value for the
block: the return of a repeated statement, `x = @repeat spec stmt` (see `_dsl_check_repeat_capture`), or a repeated
block, `x = @repeat n begin … end` (see `_dsl_check_plan_capture`). `nothing` when there is nothing to check.
"""
function _dsl_capture_check_expr(stmt, outputs::Tuple, parsed)
    isempty(outputs) && return nothing
    parsed.kind == :resolved_expr && return :(StatefulAlgorithms._dsl_check_plan_capture(_dsl_rules, $(Expr(:tuple, QuoteNode.(outputs)...))))
    parsed.kind != :resolved_expr && parsed.schedule_kind == :repeat || return nothing
    lhs = stmt.args[1]
    _, spec, inner = _dsl_parse_schedule(stmt.args[2])
    return :(StatefulAlgorithms._dsl_check_repeat_capture(_dsl_rules, $(string(lhs)), $(string(spec)), $(string(inner))))
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
function _dsl_build_statement(stmt, alias_map, context_map, known_outputs::Set{Symbol}, state_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol; include_condition = nothing, context_alias::Symbol = Symbol(), outer_locals::Set{Symbol} = Set{Symbol}())
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
    elseif stmt isa Expr && stmt.head == :local
        error("`$(stmt)`: declare locals at the top level of a block, not inside `@include_if` or `@context`.")
    end

    global_route = _dsl_build_global_route_statement(stmt, alias_map, context_map; include_condition)
    isnothing(global_route) || return global_route

    redirect_option = _dsl_build_redirect_statement(stmt, alias_map, context_map; include_condition)
    isnothing(redirect_option) || return redirect_option

    outputs = ()
    returns_expr = :(())
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
            returns_expr = _dsl_returns_spec(lhs)
        end
    end

    owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, rhs)
    if !isnothing(owned_route)
        length(outputs) == 1 || error("Owned field references like `alias.field` can only bind to one output symbol, e.g. `state = dynamics.state`.")
        output = only(outputs)
        output == owned_route.field || error("Owned field aliasing currently requires the output name to match the field name. Use `$(owned_route.field) = ...` for `$(repr(rhs))`.")
        metadata_expr = quote
            local _dsl_output = $(QuoteNode(output))
            local _dsl_owner = $(_dsl_input(owned_route.owner))
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
    parsed = isnothing(context_write) ? _dsl_parse_invocation(alias_map, context_map, rhs, known_outputs; outer_locals) : context_write
    capture_check = _dsl_capture_check_expr(stmt, outputs, parsed)
    outputs_expr = Expr(:tuple, [QuoteNode(sym) for sym in outputs]...)
    schedule_expr = _dsl_schedule_expr(parsed.schedule_kind, parsed.schedule_value, expected_schedule, owner_name)
    entity_expr = _dsl_contextual_entity_expr(context_alias)
    context_index_expr = _dsl_register_context_index_expr(context_alias)

    if parsed.kind == :entity
        customname = _dsl_customname(parsed.spec_expr, parsed.alias_name)
        algo_entry_expr = _dsl_maybe_conditional_entry_expr(_dsl_algorithm_entry_expr(parsed.alias_name, :(StatefulAlgorithms._composite_dsl_with_wires(_dsl_entity, _dsl_call_wires))), include_condition)
        share_target_expr = _dsl_share_endpoint_expr(parsed.alias_name)
        inputs_expr = _dsl_inputs_expr(parsed.inputs)
        metadata_expr = quote
            $(map(parsed.shares) do share_source
                :(StatefulAlgorithms._composite_dsl_push_local_option!(_dsl_options, _dsl_owner, StatefulAlgorithms.Share($(share_source), _dsl_owner)))
            end...)
            StatefulAlgorithms._composite_dsl_add_inputs!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.entity, _dsl_resolved.inputs)
            $(_dsl_bind_returns_expr())
        end
        return quote
            $capture_check
            local _dsl_outputs = $outputs_expr
            local _dsl_returns = $returns_expr
            # Resolve the user-facing DSL entity into a normal algorithm/state
            # object plus the routed input metadata the builder needs.
            local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_entity($(_dsl_input(parsed.spec_expr)), $inputs_expr, _dsl_returns, Val{$(QuoteNode(customname))}())
            local _dsl_entity = $entity_expr
            local _dsl_owner = $share_target_expr
            if _dsl_resolved isa StatefulAlgorithms._CompositeDSLResolved{:state}
                # States are stored separately and claim ownership of their
                # outputs immediately; an aliased state is keyed by its alias.
                $(_dsl_maybe_guard_metadata_expr(quote
                    push!(_dsl_states, _dsl_owner)
                    StatefulAlgorithms._composite_dsl_register_outputs!(_dsl_producers, _dsl_owner, _dsl_outputs)
                end, include_condition))
            else
                # Algorithms are appended to the constructor argument list and
                # then wired into the routing tables.
                local _dsl_call_wires = StatefulAlgorithms._composite_dsl_call_wires(_dsl_resolved.entity, _dsl_producers, _dsl_resolved.inputs)
                local _dsl_schedule = $schedule_expr
                push!(_dsl_algos, $algo_entry_expr)
                push!(_dsl_specification, _dsl_schedule)
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
            $capture_check
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
    algo_entry_expr = _dsl_maybe_conditional_entry_expr(_dsl_algorithm_entry_expr(parsed.alias_name, :(StatefulAlgorithms._composite_dsl_with_wires(_dsl_entity, _dsl_call_wires))), include_condition)
    share_target_expr = _dsl_share_endpoint_expr(parsed.alias_name)
    # A plain function call carries its own wires (`WithWiring`); a direct algorithm call keeps
    # routes. Decided by dispatch in one helper call each, to keep the generated code small.
    call_wires_expr = :(local _dsl_call_wires = StatefulAlgorithms._composite_dsl_call_wires(_dsl_resolved.entity, _dsl_producers, _dsl_resolved.inputs))
    call_inputs_expr = :(StatefulAlgorithms._composite_dsl_add_inputs!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.entity, _dsl_resolved.inputs))

    if parsed.kind == :keyword_call
        metadata_expr = quote
            $(map(parsed.shares) do share_source
                :(StatefulAlgorithms._composite_dsl_push_local_option!(_dsl_options, _dsl_owner, StatefulAlgorithms.Share($(share_source), _dsl_owner)))
            end...)
            $call_inputs_expr
            $(_dsl_bind_returns_expr())
        end
        return quote
            $capture_check
            local _dsl_outputs = $outputs_expr
            local _dsl_returns = $returns_expr
            local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_keyword_call(
                $(_dsl_input(parsed.spec_expr)),
                $keyword_args_expr,
                $keyword_display_expr,
                $inputs_expr,
                _dsl_returns,
                Val{$(QuoteNode(customname))}(),
            )
            local _dsl_entity = $entity_expr
            local _dsl_owner = $share_target_expr
        $call_wires_expr
            local _dsl_schedule = $schedule_expr
            push!(_dsl_algos, $algo_entry_expr)
            push!(_dsl_specification, _dsl_schedule)
            $context_index_expr
            $(_dsl_maybe_guard_metadata_expr(metadata_expr, include_condition))
        end
    end

    metadata_expr = quote
        $call_inputs_expr
        $(_dsl_bind_returns_expr())
    end
    return quote
        $capture_check
        local _dsl_outputs = $outputs_expr
        local _dsl_returns = $returns_expr
        # Function-call syntax stays on a dedicated path so we can recover
        # positional inputs and keyword values for the call's signature.
        local _dsl_resolved = StatefulAlgorithms._resolve_composite_dsl_call(
            $(_dsl_input(parsed.spec_expr)),
            $keyword_args_expr,
            $positional_values_expr,
            $positional_display_expr,
            $keyword_display_expr,
            _dsl_returns,
            $routed_positional_inputs_expr,
            $inputs_expr,
            Val{$(QuoteNode(customname))}(),
        )
        local _dsl_entity = $entity_expr
        local _dsl_owner = $share_target_expr
        $call_wires_expr
        local _dsl_schedule = $schedule_expr
        push!(_dsl_algos, $algo_entry_expr)
        push!(_dsl_specification, _dsl_schedule)
        $context_index_expr
        $(_dsl_maybe_guard_metadata_expr(metadata_expr, include_condition))
    end
end

"""
The statements with each `(; a, b) = @state(X)` written as `a = @state(X).a` and `b = @state(X).b`: from here on in
the block, `a` names the field `a` of `X`'s state.
"""
function _dsl_expand_state_reads(statements)
    expanded = Any[]
    for stmt in statements
        if stmt isa Expr && stmt.head == :(=) && !isnothing(_dsl_state_of(stmt.args[2]))
            _dsl_is_property_destructuring(stmt.args[1]) ||
                error("`$(stmt)`: take fields of `@state(X)` by name, `(; a, b) = @state(X)`, or read one inline as `@state(X).a`.")
            append!(expanded, (Expr(:(=), name, Expr(:., stmt.args[2], QuoteNode(name))) for name in only(stmt.args[1].args).args))
        else
            push!(expanded, stmt)
        end
    end
    return expanded
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
            _dsl_reject_undeclared_scheduled_assignment(branch_stmt, union(branch_known_outputs, branch_state_outputs), current_line)
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
    outer_locals::Set{Symbol} = Set{Symbol}(),
    repeat_assignments_as_blocks::Bool = true,
)
    alias_map = copy(initial_alias_map)
    context_map = copy(initial_context_map)
    # The names of enclosing blocks are in this block's scope too: each is read from where the enclosing block has it.
    declared = copy(outer_locals)
    known_outputs = copy(outer_locals)
    step_exprs = Any[]
    isempty(outer_locals) || push!(step_exprs, :(StatefulAlgorithms._composite_dsl_inherit_names!(_dsl_producers, _dsl_outer_producers, $(Tuple(outer_locals)))))
    state_fields = Any[]
    input_fields = Any[]
    state_outputs = Set{Symbol}()
    state_name = :_state
    final_expr = nothing
    current_line = nothing

    block_binds = Any[]
    pending = Any[_dsl_expand_state_reads(statements)...]
    while !isempty(pending)
        stmt = popfirst!(pending)
        if stmt isa LineNumberNode
            current_line = stmt
            continue
        end

        # `@mutable stmt`: the names `stmt` assigns may be changed by an algorithm that updates them (see `@update`).
        mutable_names = _dsl_mutable_names(stmt)
        if !isnothing(mutable_names)
            push!(step_exprs, :(union!(_dsl_mutable, $(Tuple(mutable_names)))))
            stmt = _dsl_mutable_inner(stmt)
        end

        # In a routine, `x = @repeat spec f()` is the repeated block `@repeat spec begin x = f() end`, with `local x`
        # before it when the block does not have `x` yet (see `_dsl_repeated_assignment`).
        repeated = expected_schedule == :repeat && repeat_assignments_as_blocks ? _dsl_repeated_assignment(stmt, union(known_outputs, state_outputs)) : nothing
        if !isnothing(repeated)
            if !isempty(repeated.declare)
                isnothing(current_line) || push!(step_exprs, current_line)
                push!(step_exprs, _dsl_local_declaration_expr([(name, nothing) for name in repeated.declare]))
                union!(known_outputs, repeated.declare)
                union!(declared, repeated.declare)
            end
            pushfirst!(pending, repeated.block)
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
            mappings, scope = _dsl_split_bind(stmt)
            if isnothing(scope)
                # Without a scope, the bind covers the whole block: applied after its last statement.
                push!(block_binds, mappings)
            else
                # With a scope, it covers what the statements of its `begin ... end` build: they are expanded here,
                # between a mark of what the block held before them and the rewrite. The mappings are read after
                # them, so they can name the `@context`s declared inside.
                start = gensym(:dsl_bind_start)
                push!(step_exprs, :(local $start = (length(_dsl_algos), length(_dsl_options))))
                pushfirst!(pending, Expr(:dsl_bind_end, start, mappings))
                foreach(s -> pushfirst!(pending, s), reverse(scope))
            end
            continue
        elseif stmt isa Expr && stmt.head == :dsl_bind_end
            start, mappings = stmt.args
            binds = _dsl_bind_tuple(mappings, alias_map, context_map)
            push!(step_exprs, :(StatefulAlgorithms._composite_dsl_rebind!(_dsl_algos, _dsl_options, $start[1], $start[2], $binds)))
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

        declarations = _dsl_parse_local_declaration(stmt, union(known_outputs, state_outputs, keys(alias_map)))
        if !isnothing(declarations)
            isnothing(current_line) || push!(step_exprs, current_line)
            push!(step_exprs, _dsl_local_declaration_expr(declarations))
            union!(known_outputs, first.(declarations))
            union!(declared, first.(declarations))
            continue
        end
        _dsl_reject_undeclared_scheduled_assignment(stmt, union(known_outputs, state_outputs), current_line)
        stmt = _dsl_assignment_as_call(stmt)

        _dsl_reject_input_assignment(stmt, input_fields, current_line)
        _dsl_reject_name_assignment(stmt, known_outputs, alias_map, current_line)
        step_expr = _dsl_build_statement(stmt, alias_map, context_map, known_outputs, state_outputs, expected_schedule, owner_name; outer_locals = union(known_outputs, state_outputs))
        if !isnothing(step_expr)
            step_expr = Base.remove_linenums!(step_expr)
            isnothing(current_line) || push!(step_exprs, current_line)
            push!(step_exprs, step_expr)
        end
        # Outputs become available to the statements that follow them.
        _dsl_known_outputs!(known_outputs, stmt)
    end

    for mappings in block_binds
        binds = _dsl_bind_tuple(mappings, alias_map, context_map)
        push!(step_exprs, :(StatefulAlgorithms._composite_dsl_rebind!(_dsl_algos, _dsl_options, 0, 0, $binds)))
    end

    return (; step_exprs, state_fields, input_fields, state_name, final_expr)
end
