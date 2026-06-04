"""
Parse optional scheduling wrappers around a DSL statement.

Supported wrappers:
- `@interval n expr`
- `@every n expr`
- `@repeat n expr`

Anything without an explicit wrapper is treated as schedule `1`.
"""
function _dsl_parse_schedule(ex)
    if ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@interval")
        length(ex.args) == 4 || error("@interval expects `@interval n expr`.")
        _dsl_reject_scheduled_assignment(ex)
        return (:every, ex.args[3], ex.args[4])
    elseif ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@every")
        length(ex.args) == 4 || error("@every expects `@every n expr`.")
        _dsl_reject_scheduled_assignment(ex)
        return (:every, ex.args[3], ex.args[4])
    elseif ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@repeat")
        length(ex.args) == 4 || error("@repeat expects `@repeat n expr`.")
        _dsl_reject_scheduled_assignment(ex)
        return (:repeat, ex.args[3], ex.args[4])
    end
    return (:default, :(1), ex)
end

"""Reject `@every n lhs = rhs`; schedule wrappers belong on the assignment RHS."""
function _dsl_reject_scheduled_assignment(ex)
    inner = ex.args[4]
    inner isa Expr && inner.head == :(=) || return nothing

    wrapper = ex.args[1]
    lhs = inner.args[1]
    rhs = inner.args[2]
    error("Invalid scheduled assignment `$(wrapper) $(ex.args[3]) $(lhs) = $(rhs)`. Write `$(lhs) = $(wrapper) $(ex.args[3]) $(rhs)` instead.")
end

"""Return the macro-scope alias binding for one root symbol, if any."""
function _dsl_alias_binding(alias_map, name)
    name isa Symbol || return nothing
    haskey(alias_map, name) || return nothing
    return (; name, value = alias_map[name])
end

"""
Apply macro-scope root substitution for one DSL entry expression.

This is the only place where `@alias` participates in entry parsing:

- `source` becomes `SomeAlgo`
- `source(args...)` becomes `SomeAlgo(args...)`

The alias name is carried separately so the emitted constructor args can still
become `:source => value` at the final builder step.
"""
function _dsl_rewrite_entry_root(alias_map, ex)
    binding = _dsl_alias_binding(alias_map, ex)
    !isnothing(binding) && return binding.value, binding.name

    if ex isa Expr && ex.head == :call
        binding = _dsl_alias_binding(alias_map, ex.args[1])
        !isnothing(binding) && return Expr(:call, binding.value, ex.args[2:end]...), binding.name
    end

    return ex, Symbol()
end

"""Parse `source[idx...]` as a transformed route from `source` through `getindex`."""
function _dsl_parse_ref_transform_input(alias_map, context_map, ex, destination::Symbol, known_outputs::Set{Symbol})
    ex isa Expr && ex.head == :ref && !isempty(ex.args) || return nothing

    source_expr = ex.args[1]
    indices = ex.args[2:end]
    argname = gensym(:dsl_ref)
    transform_expr = Expr(:->, argname, Expr(:call, :getindex, argname, indices...))
    display = _dsl_display_expr(ex)

    if source_expr isa Symbol && source_expr in known_outputs
        return (; kind = :simple_transform, source = source_expr, destination, transform_expr, display)
    end

    owned_route = source_expr isa Symbol ?
        _dsl_parse_symbol_alias_route_expr(alias_map, context_map, source_expr) :
        _dsl_parse_owned_route_expr(alias_map, context_map, source_expr)
    isnothing(owned_route) && return nothing
    return (; kind = :context_transform, owner = owned_route.owner, source = owned_route.source, destination, transform_expr, display)
end

"""
Parse a plain Julia function call DSL entry.

Supported function-call forms:
- `f(x)`
- `f(x, y)`
- `f("prefix", x)`
- `f(:name, x)`
- `f(x; scale = 2)`
- `f(x, y; scale = 2, offset = bias)`
- `f(a = b; x, y)`

Positional arguments may be routed symbols, quoted symbol literals, or ordinary
Julia expressions captured inline into the wrapper. Keyword values may be routed
from previous DSL outputs/@context references, captured as normal Julia
expressions, or written as same-name semicolon keywords like `; x`.
"""
function _dsl_parse_function_positional_arg(alias_map, context_map, arg, known_outputs::Set{Symbol}, index::Int)
    if arg isa Symbol && (arg in known_outputs)
        return (; kind = :routed, value = arg, display = arg), (; kind = :simple, source = arg, destination = arg)
    elseif arg isa QuoteNode && arg.value isa Symbol
        return (; kind = :literal_symbol, value = arg.value, display = _dsl_display_expr(arg)), nothing
    end

    symbol_alias_route = arg isa Symbol ? _dsl_parse_symbol_alias_route_expr(alias_map, context_map, arg) : nothing
    if !isnothing(symbol_alias_route)
        routed_name = gensym(Symbol(:dsl_pos_, index))
        routed_input = (; kind = :context_simple, owner = symbol_alias_route.owner, source = symbol_alias_route.source, destination = routed_name)
        return (; kind = :routed, value = routed_name, display = _dsl_display_expr(arg)), routed_input
    end

    transform_input = _dsl_parse_explicit_transform_input(alias_map, context_map, arg, gensym(Symbol(:dsl_pos_, index)))
    if !isnothing(transform_input)
        return (; kind = :routed, value = transform_input.destination, display = transform_input.display), transform_input
    end

    ref_input = _dsl_parse_ref_transform_input(alias_map, context_map, arg, gensym(Symbol(:dsl_pos_, index)), known_outputs)
    if !isnothing(ref_input)
        return (; kind = :routed, value = ref_input.destination, display = ref_input.display), ref_input
    end

    owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, arg)
    if !isnothing(owned_route)
        routed_name = gensym(Symbol(:dsl_pos_, index))
        routed_input = (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination = routed_name)
        return (; kind = :routed, value = routed_name, display = _dsl_display_expr(arg)), routed_input
    end

    protected_symbols = Set(known_outputs)
    rewritten = _dsl_rewrite_alias_expr(alias_map, arg, protected_symbols)
    return (; kind = :captured, value = rewritten, display = _dsl_display_expr(arg)), nothing
end

function _dsl_parse_function_call(alias_map, context_map, ex, known_outputs::Set{Symbol})
    callee, alias_name = _dsl_rewrite_entry_root(alias_map, ex.args[1])

    positional_specs = Any[]
    routed_positional_inputs = Any[]
    keyword_specs = Any[]
    routed_keyword_inputs = Any[]

    function _record_function_kwarg!(name::Symbol, value)
        if value isa Symbol && (value in known_outputs)
            push!(routed_keyword_inputs, (; kind = :simple, source = value, destination = name))
            push!(keyword_specs, (; name, routed = true, value = name, display = value))
            return
        end

        symbol_alias_route = value isa Symbol ? _dsl_parse_symbol_alias_route_expr(alias_map, context_map, value) : nothing
        if !isnothing(symbol_alias_route)
            push!(routed_keyword_inputs, (; kind = :context_simple, owner = symbol_alias_route.owner, source = symbol_alias_route.source, destination = name))
            push!(keyword_specs, (; name, routed = true, value = name, display = _dsl_display_expr(value)))
            return
        end

        transform_input = _dsl_parse_explicit_transform_input(alias_map, context_map, value, name)
        if !isnothing(transform_input)
            push!(routed_keyword_inputs, transform_input)
            push!(keyword_specs, (; name, routed = true, value = name, display = transform_input.display))
            return
        end

        ref_input = _dsl_parse_ref_transform_input(alias_map, context_map, value, name, known_outputs)
        if !isnothing(ref_input)
            push!(routed_keyword_inputs, ref_input)
            push!(keyword_specs, (; name, routed = true, value = name, display = ref_input.display))
            return
        end

        owned_route = value isa Symbol ? nothing : _dsl_parse_owned_route_expr(alias_map, context_map, value)
        if !isnothing(owned_route)
            push!(routed_keyword_inputs, (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination = name))
            push!(keyword_specs, (; name, routed = true, value = name, display = _dsl_display_expr(value)))
            return
        end

        protected_symbols = Set(known_outputs)
        rewritten = _dsl_rewrite_alias_expr(alias_map, value, protected_symbols)
        push!(keyword_specs, (; name, routed = false, value = rewritten, display = _dsl_display_expr(value)))
    end

    positional_index = 0
    for arg in ex.args[2:end]
        if arg isa Expr && arg.head == :kw
            name = arg.args[1]
            name isa Symbol || error("Function keyword names must be symbols. Got `$name`.")
            _record_function_kwarg!(name, arg.args[2])
        elseif arg isa Expr && arg.head == :parameters
            for kw in arg.args
                # Julia lowers `f(; x)` to a bare `:x` inside the parameters
                # node. Treat it like the explicit `x = x` form.
                if kw isa Symbol
                    _record_function_kwarg!(kw, kw)
                elseif kw isa Expr && kw.head == :kw
                    name = kw.args[1]
                    name isa Symbol || error("Function keyword names must be symbols. Got `$name`.")
                    _record_function_kwarg!(name, kw.args[2])
                else
                    error("Invalid keyword argument `$kw` in DSL function call.")
                end
            end
        else
            positional_index += 1
            positional_spec, routed_input = _dsl_parse_function_positional_arg(alias_map, context_map, arg, known_outputs, positional_index)
            push!(positional_specs, positional_spec)
            isnothing(routed_input) || push!(routed_positional_inputs, routed_input)
        end
    end

    return (
        kind = :function_call,
        spec_expr = callee,
        alias_name,
        positional_specs = tuple(positional_specs...),
        routed_positional_inputs = tuple(routed_positional_inputs...),
        inputs = tuple(routed_keyword_inputs...),
        keyword_specs = tuple(keyword_specs...),
    )
end

"""Emit the positional tuple passed to `FuncWrapper`, preserving routed names and literals."""
function _dsl_function_positional_args_expr(positional_specs)
    positional_exprs = map(positional_specs) do spec
        if spec.kind == :routed
            QuoteNode(spec.value)
        elseif spec.kind == :literal_symbol
            :(Core.QuoteNode($(QuoteNode(spec.value))))
        else
            esc(spec.value)
        end
    end
    return Expr(:tuple, positional_exprs...)
end

"""Emit the user-facing positional tuple kept for `FuncWrapper` display."""
function _dsl_function_positional_display_expr(positional_specs)
    return Expr(:tuple, QuoteNode.(getproperty.(positional_specs, :display))...)
end

"""Emit a plain `NamedTuple` constructor for function-call keyword forwarding."""
function _dsl_function_keyword_args_expr(keyword_specs)
    kw_exprs = map(keyword_specs) do spec
        value_expr = spec.routed ? QuoteNode(spec.value) : esc(spec.value)
        Expr(:kw, spec.name, value_expr)
    end
    return Expr(:tuple, Expr(:parameters, kw_exprs...))
end

"""Emit the user-facing keyword values kept for `FuncWrapper` display."""
function _dsl_function_keyword_display_expr(keyword_specs)
    kw_exprs = map(keyword_specs) do spec
        Expr(:kw, spec.name, QuoteNode(spec.display))
    end
    return Expr(:tuple, Expr(:parameters, kw_exprs...))
end

"""
Parse a full-context share marker inside a ProcessAlgorithm call.

Supported forms:
- `@all(source)`
- `@all(source...)`

The source may be a plain algorithm/type name or a previously declared DSL
alias.

Important: this helper must return the raw source entity. It must not wrap the
source in `IdentifiableAlgo`, because the statement builder adds the share as a
local plan option and runtime registration/matching is responsible for comparing
that raw source against any keyed identity later.
"""
function _dsl_parse_all_share_arg(alias_map, arg)
    arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@all") || error("Invalid share syntax `$arg`.")
    length(arg.args) == 3 || error("@all expects exactly one source like `@all(source)` or `@all(source...)`.")

    source_expr = arg.args[3]
    if source_expr isa Expr && source_expr.head == :...
        length(source_expr.args) == 1 || error("@all(source...) only supports one source.")
        source_expr = source_expr.args[1]
    end

    resolved_source, source_name = _dsl_rewrite_entry_root(alias_map, source_expr)
    return _dsl_known_owner_expr(esc(resolved_source), source_name)
end

"""
Parse ProcessAlgorithm call arguments.

Supported positional forms:
- `@all(source)`
- `@all(source...)`

Supported keyword forms:
- `target = produced`
- `target = @transform(x -> x * 2, produced)`
"""
function _dsl_parse_entity_call_args(alias_map, context_map, args, known_outputs::Set{Symbol})
    share_sources = Any[]
    route_kwargs = Any[]

    for arg in args
        if arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@all")
            push!(share_sources, _dsl_parse_all_share_arg(alias_map, arg))
        elseif arg isa Expr && arg.head == :kw
            push!(route_kwargs, arg)
        else
            error("ProcessAlgorithm calls in the DSL only support keyword routes and `@all(...)` share markers. Got `$arg`.")
        end
    end

    inputs = _dsl_split_route_kwargs(alias_map, context_map, route_kwargs, known_outputs)
    return inputs, tuple(share_sources...)
end

"""Parse ProcessAlgorithm keyword routes."""
function _dsl_split_route_kwargs(alias_map, context_map, kwargs, known_outputs::Set{Symbol})
    inputs = Any[]
    for kw in kwargs
        kw isa Expr && kw.head == :kw || error("Only keyword-based routes are supported for ProcessAlgorithms in the DSL.")
        destination = kw.args[1]
        destination isa Symbol || error("Route targets must be symbols. Got `$destination`.")
        source = kw.args[2]

        if source isa Symbol
            owned_route = _dsl_parse_symbol_alias_route_expr(alias_map, context_map, source)
            if !isnothing(owned_route)
                push!(inputs, (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination))
                continue
            end

            # Plain `x = produced` stays a simple route and can still become an
            # external input later if `produced` is not known yet.
            push!(inputs, (; kind = :simple, source, destination))
            continue
        end

        transform_input = _dsl_parse_explicit_transform_input(alias_map, context_map, source, destination)
        if !isnothing(transform_input)
            push!(inputs, transform_input)
            continue
        end

        ref_input = _dsl_parse_ref_transform_input(alias_map, context_map, source, destination, known_outputs)
        if !isnothing(ref_input)
            push!(inputs, ref_input)
            continue
        end

        owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, source)
        if !isnothing(owned_route)
            push!(inputs, (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination))
            continue
        end

        error("ProcessAlgorithm routes only support plain routed symbols/owned fields or explicit `@transform(f, source)` syntax. Got `$source` for `$destination`.")
    end
    return tuple(inputs...)
end

"""
Parse one right-hand-side DSL invocation.

Accepted statement bodies:
- `Algo`
- `Algo()`
- `Algo(routes...)`
- `Algo(args...)(routes...)`
- `alias`
- `alias(routes...)`
- `f(x)`
- `f(x; kw = value)`
- `@interval n expr`
- `@every n expr`
- `@repeat n expr`
- `@repeat n begin ... end`

Within ProcessAlgorithm route syntax:
- `target = produced` becomes a simple route
- `target = @transform(x -> x * 2, produced)` becomes a transformed route
"""
function _dsl_parse_invocation(alias_map, context_map, ex, known_outputs::Set{Symbol})
    if ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@repeat") && length(ex.args) == 4
        repeats_expr = ex.args[3]
        block = ex.args[4]
        if block isa Expr && block.head == :block
            # Nested `@repeat n begin ... end` becomes one pre-resolved routable
            # entity so the outer block can treat it like any other statement.
            return (
                kind = :resolved_expr,
                resolved_expr = _dsl_expand_repeated_block(block, repeats_expr, alias_map, context_map),
                alias_name = Symbol(),
                positional_specs = (),
                routed_positional_inputs = (),
                inputs = (),
                keyword_specs = (),
                schedule_kind = :default,
                schedule_value = :(1),
            )
        end
    end

    schedule_kind, schedule_value, inner = _dsl_parse_schedule(ex)

    parsed = if inner isa Symbol
        # Bare names refer to either aliases or directly to algorithms/states.
        spec_expr, alias_name = _dsl_rewrite_entry_root(alias_map, inner)
        (
            kind = :entity,
            spec_expr,
            alias_name,
            positional_specs = (),
            routed_positional_inputs = (),
            inputs = (),
            shares = (),
            keyword_specs = (),
        )
    elseif inner isa Expr && inner.head == :call
        callee = inner.args[1]
        args = inner.args[2:end]

        if callee isa Expr && callee.head == :call
            # `Algo(args...)(routes...)`: first build/resolve the entity, then
            # parse the outer keyword routes against known DSL outputs.
            spec_expr, alias_name = _dsl_rewrite_entry_root(alias_map, callee)
            inputs, shares = _dsl_parse_entity_call_args(alias_map, context_map, args, known_outputs)
            (
                kind = :entity,
                spec_expr,
                alias_name,
                positional_specs = (),
                routed_positional_inputs = (),
                inputs,
                shares,
                keyword_specs = (),
            )
        elseif isempty(args)
            spec_expr, alias_name = _dsl_rewrite_entry_root(alias_map, callee)
            (
                kind = :keyword_call,
                spec_expr,
                alias_name,
                positional_specs = (),
                routed_positional_inputs = (),
                inputs = (),
                shares = (),
                keyword_specs = (),
            )
        else
            has_parameters = any(arg -> arg isa Expr && arg.head == :parameters, args)
            has_share = any(arg -> arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@all"), args)
            has_positional = any(arg -> !(arg isa Expr && arg.head == :kw) && !(arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@all")), args)
            if has_parameters || (has_positional && !has_share)
                # Mixed positional/semicolon syntax is reserved for bare Julia
                # functions that should be wrapped in `FuncWrapper`.
                _dsl_parse_function_call(alias_map, context_map, inner, known_outputs)
            else
                # Pure keyword calls are resolved at runtime: plain functions are
                # wrapped, while ProcessAlgorithms/ProcessStates go through the
                # normal entity route path. Keep the macro as syntax lowering only.
                parsed_function = _dsl_parse_function_call(alias_map, context_map, inner, known_outputs)
                inputs, shares = _dsl_parse_entity_call_args(alias_map, context_map, args, known_outputs)
                spec_expr, alias_name = _dsl_rewrite_entry_root(alias_map, callee)
                (
                    kind = :keyword_call,
                    spec_expr,
                    alias_name,
                    positional_specs = (),
                    routed_positional_inputs = (),
                    inputs = isempty(shares) ? parsed_function.inputs : inputs,
                    shares,
                    keyword_specs = parsed_function.keyword_specs,
                )
            end
        end
    else
        spec_expr, alias_name = _dsl_rewrite_entry_root(alias_map, inner)
        (
            kind = :entity,
            spec_expr,
            alias_name,
            positional_specs = (),
            routed_positional_inputs = (),
            inputs = (),
            shares = (),
            keyword_specs = (),
        )
    end

    return (; parsed..., schedule_kind, schedule_value)
end
