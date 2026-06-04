export @CompositeAlgorithm, @Routine, @state, InlineState

"""
Lightweight inline state used by the DSL.

`@state` declarations inside a DSL block are collected into one `InlineState`.
"""
struct InlineState{Fields, Required, Defaults} <: ProcessState
    defaults::Defaults
end

"""Construct an `InlineState` with compile-time field metadata."""
@inline function _make_inline_state(defaults::Defaults, ::Val{Fields}, ::Val{Required}) where {Defaults, Fields, Required}
    InlineState{Fields, Required, Defaults}(defaults)
end

"""Fetch a required `@state` input or raise a readable error."""
@inline function _inline_state_required(context, name::Symbol)
    haskey(context, name) || error("Missing required @state input `$(name)`.")
    return getproperty(context, name)
end

"""Initialize an `InlineState` from a context or plain named tuple."""
@generated function Processes.init(state::InlineState{Fields, Required, Defaults}, context::C) where {Fields, Required, Defaults, C <: Union{Processes.AbstractContext, NamedTuple}}
    default_names = fieldnames(Defaults)
    values = Expr[]
    for field in Fields
        if field in Required
            push!(values, :(_inline_state_required(context, $(QuoteNode(field)))))
        else
            field in default_names || error("Missing default for optional @state field `$field`.")
            push!(values, :(get(context, $(QuoteNode(field)), getproperty(state.defaults, $(QuoteNode(field))))))
        end
    end

    nt_type = Expr(:curly, :NamedTuple, QuoteNode(Fields))
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        return $nt_type(($(values...),))
    end
end

"""Internal resolved representation used while expanding the DSL."""
struct _CompositeDSLResolved{Kind, Entity, Inputs}
    entity::Entity
    inputs::Inputs
end

"""ProcessAlgorithm direct-call metadata used by the DSL."""
@inline _dsl_processalgorithm_positional_names(::Type{<:ProcessAlgorithm}) = ()
@inline _dsl_processalgorithm_positional_names(algo::ProcessAlgorithm) = _dsl_processalgorithm_positional_names(typeof(algo))

"""The DSL preserves the identity the user supplied instead of uniquifying it."""
@inline _dsl_with_customname(algo, ::Val{Symbol()}) = algo
@inline _dsl_with_customname(algo, ::Val{Name}) where {Name} = algo

"""Resolve direct-call DSL syntax for a `ProcessAlgorithm` using its declared positional names."""
function _resolve_composite_dsl_algorithm_call(
    spec,
    keyword_args::NamedTuple,
    input_symbols::Tuple{Vararg{Symbol}},
    ::Val{Name},
) where {Name}
    positional_names = _dsl_processalgorithm_positional_names(spec)
    length(input_symbols) <= length(positional_names) || error("Too many positional DSL inputs for `$spec`. Expected at most $(length(positional_names)), got $(length(input_symbols)).")

    resolved = _dsl_with_customname(spec, Val(Name))
    inputs = Any[
        (; kind = :simple, source = input_symbols[idx], destination = positional_names[idx])
        for idx in eachindex(input_symbols)
    ]

    for destination in keys(keyword_args)
        source = getproperty(keyword_args, destination)
        source isa Symbol || error("Keyword arguments in direct ProcessAlgorithm call syntax must be routed symbols. Use `Algo(name = source)` for route syntax or plain function call syntax for literal keyword captures.")
        push!(inputs, (; kind = :simple, source, destination))
    end

    routed_inputs = tuple(inputs...)
    return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
end

"""Resolve one non-function DSL entity into the internal representation used by the block builder."""
function _resolve_composite_dsl_entity(spec, inputs::Tuple, output_symbols::Tuple{Vararg{Symbol}}, ::Val{Name}) where {Name}
    if spec isa Union{ProcessState, Type{<:ProcessState}}
        # States participate in the block like algorithms, but they do not accept
        # routed inputs through this syntax.
        isempty(inputs) || error("ProcessStates in the DSL cannot declare routed inputs.")
        return _CompositeDSLResolved{:state, typeof(spec), typeof(inputs)}(spec, inputs)
    elseif spec isa AbstractIdentifiableAlgo
        # Already-named/unique algorithms can pass straight through.
        return _CompositeDSLResolved{:algo, typeof(spec), typeof(inputs)}(spec, inputs)
    elseif spec isa Union{ProcessAlgorithm, Type{<:ProcessAlgorithm}}
        # Plain process algorithms are given a stable DSL-visible identity here.
        resolved = _dsl_with_customname(spec, Val(Name))
        return _CompositeDSLResolved{:algo, typeof(resolved), typeof(inputs)}(resolved, inputs)
    elseif spec isa Function
        # Bare functions are wrapped so the rest of the system can treat them like
        # normal algorithms with routed inputs/outputs.
        isempty(inputs) || error("Plain functions should use regular call syntax in the DSL, e.g. `f(x)` or `f(x; scale = 2)`.")
        wrapped = FuncWrapper(spec, (), output_symbols)
        resolved = _dsl_with_customname(wrapped, Val(Name))
        return _CompositeDSLResolved{:algo, typeof(resolved), typeof(inputs)}(resolved, inputs)
    else
        error("Unsupported DSL entry `$spec`. Expected a ProcessAlgorithm, ProcessState, or Function.")
    end
end

"""Resolve direct-call DSL syntax for either a `ProcessAlgorithm` or a plain Julia function."""
function _resolve_composite_dsl_call(
    spec,
    keyword_args::NamedTuple,
    input_symbols::Tuple{Vararg{Symbol}},
    output_symbols::Tuple{Vararg{Symbol}},
    ::Val{Name},
) where {Name}
    if spec isa Union{ProcessAlgorithm, Type{<:ProcessAlgorithm}}
        return _resolve_composite_dsl_algorithm_call(spec, keyword_args, input_symbols, Val(Name))
    end

    spec isa Function || error("Direct-call DSL syntax requires either a plain function or a ProcessAlgorithm. Got `$spec`.")

    # FuncWrapper handles the runtime call; the DSL only has to recover how the
    # wrapper should receive its routed inputs.
    wrapped = FuncWrapper(spec, input_symbols, output_symbols, keyword_args)
    resolved = _dsl_with_customname(wrapped, Val(Name))

    inputs = Any[(; kind = :simple, source, destination = source) for source in input_symbols]
    for name in keys(keyword_args)
        source = getproperty(keyword_args, name)
        source isa Symbol || continue
        push!(inputs, (; kind = :simple, source, destination = name))
    end
    routed_inputs = tuple(inputs...)
    return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
end

"""
Collect candidate routed symbols from a transform expression.

Call heads and keyword names are ignored so `sin(a)` only contributes `:a`.
"""
function _dsl_collect_transform_symbols!(symbols::Vector{Symbol}, ex)
    if ex isa Symbol
        # Preserve first-seen order so the generated transform lambda arguments
        # stay predictable and easy to reason about.
        ex in symbols || push!(symbols, ex)
    elseif ex isa Expr
        if ex.head == :call
            # Skip the callee itself; only the actual value arguments can become
            # routed inputs.
            for arg in ex.args[2:end]
                _dsl_collect_transform_symbols!(symbols, arg)
            end
        elseif ex.head == :kw
            _dsl_collect_transform_symbols!(symbols, ex.args[2])
        else
            for arg in ex.args
                _dsl_collect_transform_symbols!(symbols, arg)
            end
        end
    end
    return symbols
end

"""Rewrite routed symbols in a transform body to the generated lambda arguments."""
function _dsl_rewrite_transform_expr(ex, replacements::Dict{Symbol, Symbol})
    if ex isa Symbol
        return get(replacements, ex, ex)
    elseif ex isa Expr
        return Expr(ex.head, map(arg -> _dsl_rewrite_transform_expr(arg, replacements), ex.args)...)
    end
    return ex
end

"""
Build the transform function for a routed expression.

Only previously produced DSL symbols become lambda arguments; any other values in
the expression are left as normal lexical captures.
"""
function _dsl_transform_lambda_expr(ex, routed_symbols::Tuple{Vararg{Symbol}})
    arg_symbols = ntuple(_ -> gensym(:route_arg), length(routed_symbols))
    replacements = Dict(routed_symbols[i] => arg_symbols[i] for i in eachindex(routed_symbols))
    # Replace only the routed symbols. Any other names in the expression remain
    # normal lexical captures of the surrounding scope.
    body = _dsl_rewrite_transform_expr(ex, replacements)
    args_expr = length(arg_symbols) == 1 ? arg_symbols[1] : Expr(:tuple, arg_symbols...)
    return Expr(:->, args_expr, body)
end

"""Track which output symbols are available to later route expressions in the same DSL block."""
function _dsl_known_outputs!(known_outputs::Set{Symbol}, stmt)
    if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
        _, fields = _dsl_parse_state_statement(stmt)
        union!(known_outputs, getproperty.(fields, :name))
    elseif stmt isa Expr && stmt.head == :(=)
        union!(known_outputs, _dsl_parse_output_symbols(stmt.args[1]))
    end
    return known_outputs
end

"""Recreate parsed input specs inside the emitted DSL block."""
function _dsl_inputs_expr(input_specs)
    specs = map(input_specs) do spec
        if spec.kind == :simple
            # Keep the emitted structure plain NamedTuples so the builder-side
            # route code stays easy to inspect at runtime.
            :( (; kind = :simple, source = $(QuoteNode(spec.source)), destination = $(QuoteNode(spec.destination)) ) )
        else
            :( (; kind = :transform, sources = $(QuoteNode(spec.sources)), destination = $(QuoteNode(spec.destination)), transform = $(esc(spec.transform_expr)) ) )
        end
    end
    return Expr(:tuple, specs...)
end

"""Emit keyword values for direct-call DSL syntax."""
_dsl_keyword_value_expr(value) = value isa Symbol ? QuoteNode(value) : esc(value)

"""
Turn parsed DSL input specs into concrete `Route` objects.

Simple routes are converted directly. Transform routes remain intentionally
conservative for now and only support sources that all belong to the same
producer subcontext.
"""
function _composite_dsl_add_routes!(options::Vector{Any}, producers::Dict{Symbol, Any}, external_inputs::Vector{Pair{Symbol, Symbol}}, target, inputs::Tuple)
    for input in inputs
        if input.kind == :simple
            source = input.source
            destination = input.destination
            if haskey(producers, source)
                push!(options, Route(producers[source] => target, source => destination))
            else
                ext_mapping = source => source
                ext_mapping in external_inputs || push!(external_inputs, ext_mapping)
            end
        else
            sources = input.sources
            isempty(sources) && error("Transform routes must reference at least one previously produced symbol.")

            missing = filter(source -> !haskey(producers, source), sources)
            isempty(missing) || error("Transform routes currently only support previously produced symbols. Missing: $(missing)")

            # The current routing backend stores one origin subcontext per route.
            # Keep the DSL syntax broad enough for future multi-context routes, but
            # reject cross-producer transforms clearly for now.
            owner = producers[first(sources)]
            all(source -> producers[source] === owner, sources) || error("Transform routes currently require all source symbols to come from the same producer. Got $(sources)")

            push!(options, Route(owner => target, (sources => input.destination); transform = input.transform))
        end
    end
    return options
end

"""Register outputs as the current producer for later routed lookups."""
function _composite_dsl_register_outputs!(producers::Dict{Symbol, Any}, owner, outputs::Tuple{Vararg{Symbol}})
    for output in outputs
        # Later statements resolve symbols by asking this table who currently
        # owns a given output name.
        producers[output] = owner
    end
    return producers
end

"""
Bind the outputs produced by one DSL statement.

If the output already belongs to an inline `@state`, keep that state as the
owner and add a writeback route instead of rebinding the symbol.
"""
function _composite_dsl_bind_outputs!(options::Vector{Any}, producers::Dict{Symbol, Any}, target, outputs::Tuple{Vararg{Symbol}})
    for output in outputs
        if haskey(producers, output) && producers[output] isa ProcessState
            push!(options, Route(producers[output] => target, output => output))
        else
            producers[output] = target
        end
    end
    return producers
end

"""Build the inline state expression used by both `@state` and the block DSL."""
function _dsl_expand_state_expr(fields)
    field_names = Expr(:tuple, [QuoteNode(field.name) for field in fields]...)
    required_names = Expr(:tuple, [QuoteNode(field.name) for field in fields if field.required]...)
    default_kws = [Expr(:kw, field.name, esc(field.default)) for field in fields if !field.required]
    defaults_expr = Expr(:tuple, Expr(:parameters, default_kws...))

    return quote
        # The field metadata is kept in the type so init can stay fully inferred.
        Processes._make_inline_state($defaults_expr, Val{$field_names}(), Val{$required_names}())
    end
end

"""Parse one field entry from a `@state` declaration."""
function _dsl_parse_state_entry(ex)
    if ex isa Symbol
        return (; name = ex, required = true, default = nothing)
    elseif ex isa Expr && ex.head == :(=)
        lhs = ex.args[1]
        lhs isa Symbol || error("@state fields must be plain symbols or `name = default` assignments. Got `$lhs`.")
        return (; name = lhs, required = false, default = ex.args[2])
    end
    error("@state only supports entries like `a` or `a = 1`. Got `$ex`.")
end

"""Collect field entries from a `@state` declaration, ignoring line nodes."""
function _dsl_collect_state_fields(args)
    raw_entries = Any[]
    for arg in args
        if arg isa LineNumberNode
            continue
        elseif arg isa Expr && arg.head == :block
            append!(raw_entries, [item for item in arg.args if !(item isa LineNumberNode)])
        else
            push!(raw_entries, arg)
        end
    end

    isempty(raw_entries) && error("@state requires at least one field.")
    return map(_dsl_parse_state_entry, raw_entries)
end

"""
Parse a `@state` statement inside the DSL block.

Supported forms:
- `@state a = 1`
- `@state begin ... end`
- `@state mystate begin ... end`
"""
function _dsl_parse_state_statement(stmt)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state") || error("Invalid @state statement `$stmt`.")
    args = Any[stmt.args[i] for i in 3:length(stmt.args)]
    isempty(args) && error("@state requires at least one field.")

    if length(args) >= 2 && args[1] isa Symbol
        return args[1], _dsl_collect_state_fields(args[2:end])
    end

    return :_state, _dsl_collect_state_fields(args)
end

"""Accumulate one `@state` statement into the current block-level inline state."""
function _dsl_merge_state_statement!(state_fields::Vector, state_name::Symbol, stmt)
    this_state_name, this_state_fields = _dsl_parse_state_statement(stmt)
    state_name == :_state || this_state_name == :_state || this_state_name == state_name || error("Use a single state name inside one DSL block. Got `$state_name` and `$this_state_name`.")
    append!(state_fields, this_state_fields)
    return this_state_name == :_state ? state_name : this_state_name
end

"""Generate the setup expression for the collected block-level inline state."""
function _dsl_state_setup_expr(state_fields, state_name::Symbol)
    isempty(state_fields) && return nothing

    field_names = getproperty.(state_fields, :name)
    length(unique(field_names)) == length(field_names) || error("Duplicate @state field names are not allowed: $(field_names)")

    state_expr = _dsl_expand_state_expr(state_fields)
    outputs_expr = Expr(:tuple, [QuoteNode(field.name) for field in state_fields]...)
    return quote
        local _dsl_state = $state_expr
        push!(_dsl_states, $(QuoteNode(state_name)) => _dsl_state)
        Processes._composite_dsl_register_outputs!(_dsl_producers, _dsl_state, $outputs_expr)
    end
end

"""
Parse the left-hand side of a DSL assignment.

Supported output bindings:
- `x = ...`
- `a, b = ...`

Tuple bindings must contain only plain symbols.
"""
function _dsl_parse_output_symbols(lhs)
    if lhs isa Symbol
        return (lhs,)
    elseif lhs isa Expr && lhs.head == :tuple
        all(x -> x isa Symbol, lhs.args) || error("Multi-output bindings must use plain symbols like `a, b = algo`.")
        return tuple(lhs.args...)
    end
    error("Unsupported left-hand side in the DSL: `$lhs`.")
end

"""
Parse an alias declaration.

Supported form:
- `@alias name = SomeAlgo`
- `@alias name = SomeAlgo(args...)`

The alias name must be a plain symbol.
"""
function _dsl_parse_alias(stmt)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@alias") || error("Invalid alias statement `$stmt`.")
    length(stmt.args) == 3 || error("@alias expects a single assignment like `@alias src = SourceAlgo`.")
    assign = stmt.args[3]
    assign isa Expr && assign.head == :(=) || error("@alias expects a single assignment like `@alias src = SourceAlgo`.")
    lhs = assign.args[1]
    lhs isa Symbol || error("@alias names must be symbols. Got `$lhs`.")
    return lhs => assign.args[2]
end

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
        return (:every, ex.args[3], ex.args[4])
    elseif ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@every")
        length(ex.args) == 4 || error("@every expects `@every n expr`.")
        return (:every, ex.args[3], ex.args[4])
    elseif ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@repeat")
        length(ex.args) == 4 || error("@repeat expects `@repeat n expr`.")
        return (:repeat, ex.args[3], ex.args[4])
    end
    return (:default, :(1), ex)
end

"""Resolve a DSL alias when the callee is referenced by name."""
function _dsl_resolve_alias(alias_map, ex)
    if ex isa Symbol && haskey(alias_map, ex)
        return alias_map[ex], ex
    end
    return ex, Symbol()
end

"""Resolve constructor syntax while preserving alias-based custom names."""
function _dsl_resolve_constructor_expr(alias_map, ex)
    if ex isa Symbol
        return _dsl_resolve_alias(alias_map, ex)
    elseif ex isa Expr && ex.head == :call && ex.args[1] isa Symbol && haskey(alias_map, ex.args[1])
        isempty(ex.args[2:end]) || error("Aliases can only be called without constructor arguments. Alias the instantiated form instead, e.g. `@alias x = Algo(args...)`.")
        return alias_map[ex.args[1]], ex.args[1]
    end
    return ex, Symbol()
end

"""
Parse a plain Julia function call DSL entry.

Supported function-call forms:
- `f(x)`
- `f(x, y)`
- `f(x; scale = 2)`
- `f(x, y; scale = 2, offset = bias)`

All positional arguments must be plain symbols. Keyword values may be symbols or
arbitrary Julia expressions and are forwarded to `FuncWrapper`.
"""
function _dsl_parse_function_call(alias_map, ex)
    callee, alias_name = _dsl_resolve_alias(alias_map, ex.args[1])

    input_symbols = Symbol[]
    keyword_pairs = Pair{Symbol, Any}[]

    for arg in ex.args[2:end]
        if arg isa Expr && arg.head == :parameters
            for kw in arg.args
                kw isa Expr && kw.head == :kw || error("Invalid keyword argument `$kw` in DSL function call.")
                name = kw.args[1]
                name isa Symbol || error("Function keyword names must be symbols. Got `$name`.")
                value = kw.args[2]
                push!(keyword_pairs, name => value)
            end
        else
            # Plain function positional arguments are routed by position; keep
            # this syntax intentionally narrow so it stays readable.
            arg isa Symbol || error("Plain function positional arguments in the DSL must be routed symbols. Got `$arg`.")
            push!(input_symbols, arg)
        end
    end

    return (
        kind = :function_call,
        spec_expr = callee,
        alias_name,
        inputs = (),
        input_symbols = tuple(input_symbols...),
        keyword_pairs = tuple(keyword_pairs...),
    )
end

"""
Parse a full-context share marker inside a ProcessAlgorithm call.

Supported forms:
- `@all(source)`
- `@all(source...)`

The source may be a plain algorithm/type name or a previously declared DSL alias.
"""
function _dsl_parse_all_share_arg(alias_map, arg)
    arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@all") || error("Invalid share syntax `$arg`.")
    length(arg.args) == 3 || error("@all expects exactly one source like `@all(source)` or `@all(source...)`.")

    source_expr = arg.args[3]
    if source_expr isa Expr && source_expr.head == :...
        length(source_expr.args) == 1 || error("@all(source...) only supports one source.")
        source_expr = source_expr.args[1]
    end

    resolved_source, source_name = _dsl_resolve_constructor_expr(alias_map, source_expr)
    return source_name == Symbol() ? resolved_source : :(Processes.IdentifiableAlgo($(esc(resolved_source)), $(QuoteNode(source_name))))
end

"""
Parse ProcessAlgorithm call arguments.

Supported positional forms:
- `@all(source)`
- `@all(source...)`

Supported keyword forms:
- `target = produced`
- `target = produced + other`
"""
function _dsl_parse_entity_call_args(alias_map, args, known_outputs::Set{Symbol})
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

    inputs = _dsl_split_route_kwargs(route_kwargs, known_outputs)
    return inputs, tuple(share_sources...)
end

"""
Parse ProcessAlgorithm keyword routes.

Simple symbol values become normal routes. Expressions become transformed routes,
using any already-known DSL outputs as routed inputs and leaving the rest of the
expression captured normally.
"""
function _dsl_split_route_kwargs(kwargs, known_outputs::Set{Symbol})
    inputs = Any[]
    for kw in kwargs
        kw isa Expr && kw.head == :kw || error("Only keyword-based routes are supported for ProcessAlgorithms in the DSL.")
        destination = kw.args[1]
        destination isa Symbol || error("Route targets must be symbols. Got `$destination`.")
        source = kw.args[2]

        if source isa Symbol
            # Plain `x = produced` stays a simple route and can still become an
            # external input later if `produced` is not known yet.
            push!(inputs, (; kind = :simple, source, destination))
            continue
        end

        routed_symbols = Symbol[]
        _dsl_collect_transform_symbols!(routed_symbols, source)
        # Only previously-seen DSL outputs become routed inputs. Everything else
        # in the expression remains a normal captured value.
        filter!(in(known_outputs), routed_symbols)
        isempty(routed_symbols) && error("Transform route for `$destination` must reference at least one previously named output.")

        routed_tuple = tuple(routed_symbols...)
        transform_expr = _dsl_transform_lambda_expr(source, routed_tuple)
        push!(inputs, (; kind = :transform, sources = routed_tuple, destination, transform_expr))
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
- `target = produced + other` becomes a transform route

Only symbols already produced earlier in the same DSL block are treated as routed
transform inputs. Any other values in the expression remain normal Julia captures.
"""
function _dsl_parse_invocation(alias_map, ex, known_outputs::Set{Symbol})
    if ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@repeat") && length(ex.args) == 4
        repeats_expr = ex.args[3]
        block = ex.args[4]
        if block isa Expr && block.head == :block
            # Nested `@repeat n begin ... end` becomes one pre-resolved routable
            # entity so the outer block can treat it like any other statement.
            return (
                kind = :resolved_expr,
                resolved_expr = _dsl_expand_repeated_block(block, repeats_expr),
                alias_name = Symbol(),
                inputs = (),
                input_symbols = (),
                keyword_pairs = (),
                schedule_kind = :default,
                schedule_value = :(1),
            )
        end
    end

    schedule_kind, schedule_value, inner = _dsl_parse_schedule(ex)

    parsed = if inner isa Symbol
        # Bare names refer to either aliases or directly to algorithms/states.
        spec_expr, alias_name = _dsl_resolve_constructor_expr(alias_map, inner)
        (
            kind = :entity,
            spec_expr,
            alias_name,
            inputs = (),
            shares = (),
            input_symbols = (),
            keyword_pairs = (),
        )
    elseif inner isa Expr && inner.head == :call
        callee = inner.args[1]
        args = inner.args[2:end]

        if callee isa Expr && callee.head == :call
            # `Algo(args...)(routes...)`: first build/resolve the entity, then
            # parse the outer keyword routes against known DSL outputs.
            spec_expr, alias_name = _dsl_resolve_constructor_expr(alias_map, callee)
            inputs, shares = _dsl_parse_entity_call_args(alias_map, args, known_outputs)
            (
                kind = :entity,
                spec_expr,
                alias_name,
                inputs,
                shares,
                input_symbols = (),
                keyword_pairs = (),
            )
        elseif isempty(args)
            spec_expr, alias_name = _dsl_resolve_constructor_expr(alias_map, inner)
            (
                kind = :entity,
                spec_expr,
                alias_name,
                inputs = (),
                shares = (),
                input_symbols = (),
                keyword_pairs = (),
            )
        else
            has_parameters = any(arg -> arg isa Expr && arg.head == :parameters, args)
            has_share = any(arg -> arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@all"), args)
            has_positional = any(arg -> !(arg isa Expr && arg.head == :kw) && !(arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@all")), args)
            if has_parameters || (has_positional && !has_share)
                # Mixed positional/semicolon syntax is reserved for bare Julia
                # functions that should be wrapped in `FuncWrapper`.
                _dsl_parse_function_call(alias_map, inner)
            else
                # Pure keyword calls are interpreted as ProcessAlgorithm routes.
                spec_expr, alias_name = _dsl_resolve_alias(alias_map, callee)
                inputs, shares = _dsl_parse_entity_call_args(alias_map, args, known_outputs)
                (
                    kind = :entity,
                    spec_expr,
                    alias_name,
                    inputs,
                    shares,
                    input_symbols = (),
                    keyword_pairs = (),
                )
            end
        end
    else
        spec_expr, alias_name = _dsl_resolve_constructor_expr(alias_map, inner)
        (
            kind = :entity,
            spec_expr,
            alias_name,
            inputs = (),
            shares = (),
            input_symbols = (),
            keyword_pairs = (),
        )
    end

    return (; parsed..., schedule_kind, schedule_value)
end

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

"""Validate schedule usage and turn it into the constructor specification entry."""
function _dsl_schedule_expr(schedule_kind::Symbol, schedule_value, expected_schedule::Symbol, owner_name::Symbol)
    if schedule_kind == :default
        return :(1)
    elseif expected_schedule == :none
        got = schedule_kind == :every ? "@interval" : "@repeat"
        error("Use plain entries inside `@$(owner_name) ... begin ... end`, not `$got`.")
    elseif schedule_kind == expected_schedule
        return esc(schedule_value)
    else
        expected = expected_schedule == :every ? "@interval" : "@repeat"
        got = schedule_kind == :every ? "@interval" : "@repeat"
        error("Use `$expected` inside `@$owner_name`, not `$got`.")
    end
end

"""Emit either `algo` or `:alias => algo` for the target constructor call."""
function _dsl_algorithm_entry_expr(alias_name::Symbol)
    alias_name == Symbol() ? :(_dsl_resolved.entity) : :($(QuoteNode(alias_name)) => _dsl_resolved.entity)
end

"""Emit the share endpoint expression matching the algorithm identity that will be registered."""
function _dsl_share_endpoint_expr(alias_name::Symbol)
    alias_name == Symbol() ? :(_dsl_resolved.entity) : :(Processes.IdentifiableAlgo(_dsl_resolved.entity, $(QuoteNode(alias_name))))
end

"""
Build one executable DSL statement inside a composite or routine block.

Accepted top-level statements inside the block:
- `@state ...`
- `@alias ...`
- bare algorithm/state/function entries
- assignments like `x = ...` or `a, b = ...`
- scheduled entries via `@interval`, `@every`, or `@repeat`

`@finally` is recognized only to emit the current "not implemented" error.
"""
function _dsl_build_statement(stmt, alias_map, known_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol)
    if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@alias")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@finally")
        error("@finally is not implemented yet.")
    end

    outputs = ()
    rhs = stmt
    if stmt isa Expr && stmt.head == :(=)
        outputs = _dsl_parse_output_symbols(stmt.args[1])
        rhs = stmt.args[2]
    end

    parsed = _dsl_parse_invocation(alias_map, rhs, known_outputs)
    outputs_expr = Expr(:tuple, [QuoteNode(sym) for sym in outputs]...)
    schedule_expr = _dsl_schedule_expr(parsed.schedule_kind, parsed.schedule_value, expected_schedule, owner_name)

    if parsed.kind == :entity
        customname = _dsl_customname(parsed.spec_expr, parsed.alias_name)
        algo_entry_expr = _dsl_algorithm_entry_expr(parsed.alias_name)
        share_target_expr = _dsl_share_endpoint_expr(parsed.alias_name)
        inputs_expr = _dsl_inputs_expr(parsed.inputs)
        return quote
            local _dsl_outputs = $outputs_expr
            # Resolve the user-facing DSL entity into a normal algorithm/state
            # object plus the routed input metadata the builder needs.
            local _dsl_resolved = Processes._resolve_composite_dsl_entity($(esc(parsed.spec_expr)), $inputs_expr, _dsl_outputs, Val{$(QuoteNode(customname))}())
            if _dsl_resolved isa Processes._CompositeDSLResolved{:state}
                # Inline states are stored separately and claim ownership of
                # their outputs immediately.
                push!(_dsl_states, _dsl_resolved.entity)
                Processes._composite_dsl_register_outputs!(_dsl_producers, _dsl_resolved.entity, _dsl_outputs)
            else
                # Algorithms are appended to the constructor argument list and
                # then wired into the routing tables.
                push!(_dsl_algos, $algo_entry_expr)
                push!(_dsl_specification, Int($schedule_expr))
                $(map(parsed.shares) do share_source
                    :(push!(_dsl_options, Processes.Share($(share_source), $share_target_expr)))
                end...)
                Processes._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_resolved.entity, _dsl_resolved.inputs)
                Processes._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_resolved.entity, _dsl_outputs)
            end
        end
    end

    if parsed.kind == :resolved_expr
        algo_entry_expr = _dsl_algorithm_entry_expr(parsed.alias_name)
        return quote
            local _dsl_outputs = $outputs_expr
            # Repeated inner blocks already expand to one resolved entity, so the
            # outer builder only has to wire and register them.
            local _dsl_resolved = $(parsed.resolved_expr)
            push!(_dsl_algos, $algo_entry_expr)
            push!(_dsl_specification, Int($schedule_expr))
            Processes._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_resolved.entity, _dsl_resolved.inputs)
            Processes._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_resolved.entity, _dsl_outputs)
        end
    end

    input_symbols_expr = Expr(:tuple, [QuoteNode(sym) for sym in parsed.input_symbols]...)
    keyword_args_expr = Expr(:tuple, Expr(:parameters, [
        Expr(:kw, name, _dsl_keyword_value_expr(value)) for (name, value) in parsed.keyword_pairs
    ]...))
    customname = _dsl_customname(parsed.spec_expr, parsed.alias_name)
    algo_entry_expr = _dsl_algorithm_entry_expr(parsed.alias_name)

    return quote
        local _dsl_outputs = $outputs_expr
        # Function-call syntax stays on a dedicated path so we can recover
        # positional inputs and keyword captures for `FuncWrapper`.
        local _dsl_resolved = Processes._resolve_composite_dsl_call(
            $(esc(parsed.spec_expr)),
            $keyword_args_expr,
            $input_symbols_expr,
            _dsl_outputs,
            Val{$(QuoteNode(customname))}(),
        )
        push!(_dsl_algos, $algo_entry_expr)
        push!(_dsl_specification, Int($schedule_expr))
        Processes._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_resolved.entity, _dsl_resolved.inputs)
        Processes._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_resolved.entity, _dsl_outputs)
    end
end

"""
Walk a DSL block once and collect the state declarations plus executable statements.

This is shared by the top-level `@CompositeAlgorithm`/`@Routine` expansion and the
inner `@repeat n begin ... end` block expansion so they stay in sync.
"""
function _dsl_collect_block(statements, expected_schedule::Symbol, owner_name::Symbol)
    alias_map = Dict{Symbol, Any}()
    known_outputs = Set{Symbol}()
    step_exprs = Expr[]
    state_fields = Any[]
    state_name = :_state

    for stmt in statements
        if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
            # States are collected first and emitted once for the whole block.
            state_name = _dsl_merge_state_statement!(state_fields, state_name, stmt)
            _dsl_known_outputs!(known_outputs, stmt)
            continue
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@alias")
            # Aliases only affect later statements, so store them and keep moving.
            alias = _dsl_parse_alias(stmt)
            alias_map[alias.first] = alias.second
            continue
        end

        step_expr = _dsl_build_statement(stmt, alias_map, known_outputs, expected_schedule, owner_name)
        isnothing(step_expr) || push!(step_exprs, step_expr)
        # Outputs become available to the statements that follow them.
        _dsl_known_outputs!(known_outputs, stmt)
    end

    return (; step_exprs, state_fields, state_name)
end

"""Create an `InlineState` value directly."""
macro state(args...)
    fields = _dsl_collect_state_fields(args)
    return _dsl_expand_state_expr(fields)
end

"""Expand a top-level DSL block into either a `CompositeAlgorithm` or a `Routine`."""
function _dsl_expand_loopalgorithm(block, constructor_name::Symbol, expected_schedule::Symbol)
    statements = block isa Expr && block.head == :block ? [stmt for stmt in block.args if !(stmt isa LineNumberNode)] : [block]
    collected = _dsl_collect_block(statements, expected_schedule, constructor_name)

    state_setup_expr = _dsl_state_setup_expr(collected.state_fields, collected.state_name)

    return quote
        let
            # Keep the emitted block literal and local so the resulting macro
            # expansion is easy to inspect in lowered code.
            local _dsl_algos = Any[]
            local _dsl_states = Any[]
            local _dsl_options = Any[]
            local _dsl_specification = Int[]
            local _dsl_producers = Dict{Symbol, Any}()
            local _dsl_external_inputs = Pair{Symbol, Symbol}[]

            $(isnothing(state_setup_expr) ? nothing : state_setup_expr)
            $(collected.step_exprs...)

            isempty(_dsl_algos) && error("`@$constructor_name` requires at least one algorithm entry.")
            # Build the final `CompositeAlgorithm`/`Routine` using the same
            # constructor surface users would write by hand.
            getproperty(Processes, $(QuoteNode(constructor_name)))(_dsl_algos..., Tuple(_dsl_specification), _dsl_states..., _dsl_options...)
        end
    end
end

"""Expand the body used inside `@repeat n begin ... end` into a `SimpleAlgo`."""
function _dsl_expand_simplealgorithm_resolved(block)
    statements = block isa Expr && block.head == :block ? [stmt for stmt in block.args if !(stmt isa LineNumberNode)] : [block]
    collected = _dsl_collect_block(statements, :none, :repeat)

    state_setup_expr = _dsl_state_setup_expr(collected.state_fields, collected.state_name)

    return quote
        let
            # The inner repeated block is built exactly once as a plain
            # `SimpleAlgo`, then wrapped by the outer `Routine`.
            local _dsl_algos = Any[]
            local _dsl_states = Any[]
            local _dsl_options = Any[]
            local _dsl_specification = Int[]
            local _dsl_producers = Dict{Symbol, Any}()
            local _dsl_external_inputs = Pair{Symbol, Symbol}[]

            $(isnothing(state_setup_expr) ? nothing : state_setup_expr)
            $(collected.step_exprs...)

            isempty(_dsl_algos) && error("`@repeat n begin ... end` requires at least one algorithm entry.")
            local _dsl_algo = Processes.SimpleAlgo(_dsl_algos..., _dsl_states..., _dsl_options...)
            # Return the same resolved wrapper the outer builder expects from any
            # other DSL statement.
            local _dsl_inputs = Tuple((; kind = :simple, source = input.first, destination = input.second) for input in _dsl_external_inputs)
            Processes._CompositeDSLResolved{:algo, typeof(_dsl_algo), typeof(_dsl_inputs)}(_dsl_algo, _dsl_inputs)
        end
    end
end

"""Wrap a repeated DSL block in a `Routine`, then expose it as one routable entity."""
function _dsl_expand_repeated_block(block, repeats_expr)
    inner_expr = _dsl_expand_simplealgorithm_resolved(block)
    return quote
        let
            local _dsl_inner = $inner_expr
            local _dsl_repeats = Int($(esc(repeats_expr)))
            # `Unique` gives the repeated block one stable identity so normal
            # routes and aliases can target it from the outer DSL block.
            local _dsl_algo = Processes.Unique(Processes.Routine(_dsl_inner.entity, (_dsl_repeats,)))
            local _dsl_inputs = _dsl_inner.inputs
            Processes._CompositeDSLResolved{:algo, typeof(_dsl_algo), typeof(_dsl_inputs)}(_dsl_algo, _dsl_inputs)
        end
    end
end

"""
Build a `CompositeAlgorithm` from a declarative DSL block.

Supported block contents
========================

State declarations:
- `@state x`
- `@state x = 1`
- `@state begin ... end`
- `@state mystate begin ... end`

Alias declarations:
- `@alias source = SomeAlgo`
- `@alias source = SomeAlgo(args...)`

Plain entries:
- `Algo`
- `Algo()`
- `alias`

Assignments:
- `x = Algo`
- `x = Algo()`
- `a, b = Algo(...)`

ProcessAlgorithm routes:
- `x = Algo(input = produced)`
- `x = Algo(left = a, right = b)`
- `x = Algo(value = produced * 2)`
- `x = Algo(value = produced + passthrough + bias)`
- `x = SomeAlgo(args...)(input = produced)`

Plain-function entries:
- `x = f(produced)`
- `x = f(produced, other)`
- `x = f(produced; scale = 2)`
- `x = f(produced; scale = factor)`

Scheduling:
- `x = @interval n Algo(...)`
- `x = @every n Algo(...)`
- `x = @interval n f(produced)`
- `x = @repeat n begin ... end`

Current transform-route rules
=============================

When a ProcessAlgorithm keyword value is an expression instead of a plain symbol,
the DSL treats it as a transformed route. For example:

`consumer(value = a + b)`

is parsed as a route into `value` with a generated transform function. At the
moment, all routed symbols inside that transform must come from the same producer
subcontext. Cross-producer transforms are intentionally left for later work.

State rebinding
===============

If an output name already belongs to the inline DSL state, assigning to that name
does not replace the state owner. Instead, the produced value is routed back into
that state slot.
"""
macro CompositeAlgorithm(block)
    _dsl_expand_loopalgorithm(block, :CompositeAlgorithm, :every)
end

"""
Build a `Routine` from a declarative DSL block.

The supported statement syntax is the same as `@CompositeAlgorithm`, except that
the scheduling wrapper expected inside the block is `@repeat n expr` instead of
`@interval n expr`.

Examples:
- `x = Algo(input = value)`
- `x = @repeat 10 Algo(input = value)`
- `y = @repeat 5 begin ... end`
- `z = f(value; scale = 2)`
"""
macro Routine(block)
    _dsl_expand_loopalgorithm(block, :Routine, :repeat)
end
