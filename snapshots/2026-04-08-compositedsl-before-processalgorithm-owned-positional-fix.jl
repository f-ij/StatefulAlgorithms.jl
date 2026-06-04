export @CompositeAlgorithm, @Routine, @state

"""
Strict DSL implementation requirement
====================================

This file must remain a pure syntax-to-constructor lowering layer.

The DSL may only expand user syntax into the normal constructors, options, and
existing runtime types already provided by the package. Do not add custom
runtime behavior here: no new execution wrappers, no custom stepping/init
logic, no hidden runtime carrier types, and no special-case runtime hooks.

In particular, this file should almost never manufacture `IdentifiableAlgo`
objects itself. Identity/key assignment belongs to the normal constructor,
registry, and runtime matching layers. The DSL should lower to the raw entities
the user wrote, plus ordinary `:key => value`, `Route(...)`, and `Share(...)`
surface syntax, and then let the existing runtime machinery relate those raw
entities to keyed registrations later.

If some DSL syntax needs capabilities that the existing constructor/type surface
cannot express, add those facilities elsewhere in the package first and then
lower to them from this file.

The DSL should only reject malformed DSL syntax. It should not add extra
assert-style checking for runtime types, runtime values, or semantic validity
beyond what the existing constructors and runtime structs already enforce
themselves. If a DSL path needs a more readable failure, wrap it in existing
runtime constructor surfaces and let those runtime objects throw the
understandable error there.

Constructor-call routing rule
-----------------------------

For routed DSL entries, the macro must treat the entire expression to the left
of the final route-call brackets as the constructor/entity expression and pass
it through unchanged into the eventual `CompositeAlgorithm`/`Routine`
constructor surface.

Examples:

- `Walker()` lowers as an entry built from `Walker` with no routes
- `InsertNoise(1000)(scale = dt)` lowers as an entry built from
  `InsertNoise(1000)`, with routes taken only from the final `(scale = dt)`
- `Walker()()` means the left side is `Walker()` and the final `()` contributes
  no routes

The DSL layer must not try to initialize or reinterpret that left-hand
constructor expression on its own.

`@context` constraint
---------------------

`@context` is macro-expansion-only syntax. It is not allowed to introduce any
runtime wrapper, helper algorithm, carrier type, custom init/step logic, or
other execution behavior in this file.

Its job is only to let later DSL expressions refer to subcontexts that will
eventually be reachable through a produced algorithm's registry surface. The
lowered result must still be expressed only in terms of the package's normal
constructors and options, ending up as ordinary route/share specifications.

In particular, the intended lowering shape is along the lines of:

- `c1.plus_capture.buffer` -> a normal route source like `plus.plus_capture`
- `c1[plus_capture].buffer` -> a normal route source like `plus[plus_capture]`
- `n.changeable_seed` -> the nested inline-state owner inside `capture_noise`,
  i.e. a normal route source like `capture_noise._state` with source
  `:changeable_seed`

and from there the existing `Route`/`Share` resolution machinery is responsible
for figuring out what those references map to later. The DSL layer must not add
any `Var`-like intermediate structure for this, and it must not attempt to
resolve the runtime registry itself. It also must not validate whether the
lowered endpoint expression is already supported elsewhere; if the rest of the
package rejects it later, that is outside the macro's responsibility.

`@alias` constraint
-------------------

`@alias` is also macro-expansion-only syntax. It is just a naming layer inside
the DSL block:

- `@alias x = Algo` means later `x` refers to `Algo`
- `@alias x = Algo(123)` means later `x` refers to `Algo(123)`
- `x(args...)` rewrites by replacing the root `x` with the aliased expression
- writing the raw aliased expression directly, e.g. `Algo(...)`, does not
  recover the alias name or emit a keyed entry for `x`

The DSL must not impose extra constructor restrictions on aliases beyond normal
Julia syntax.

Identity/keying constraint
--------------------------

The DSL may emit keyed constructor entries like:

- `:name => algo`

because that is part of the ordinary `CompositeAlgorithm` / `Routine`
constructor surface.

But outside of those constructor entries, the default should still be to keep
using raw entities:

- `Route(raw_source => raw_target, ...)`
- `Share(raw_source, raw_target)`

There is one deliberate exception: if the DSL already knows the final stable key
for an endpoint at expansion time, it should prefer the keyed owner expression
over the raw value. In practice this means:

- inline `@state` owners should use their known state key (for example `:_state`)
- named aliases used as share/route endpoints should use their known alias key

Why: once the key is already part of the DSL syntax, preserving that keyed
identity in emitted routes/options makes later composition and renaming work
through key replacement instead of depending on raw-value matching. When no
stable key is known yet, the DSL should continue to fall back to raw entities.

Why: keyed/identifiable wrappers are runtime registration artifacts. The normal
matching system is supposed to make keyed registrations comparable to the raw
entities they came from. If the macro manufactures its own `IdentifiableAlgo`
wrappers, it risks creating identities that disagree with what the runtime
would have registered on its own, especially for loop algorithms and nested
DSL-produced entities.
"""

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
    elseif spec isa Union{SteppableAlgorithm, Type{<:SteppableAlgorithm}}
        # Plain algorithms/loop algorithms are passed through and keyed by the
        # normal constructor surface later.
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
        error("Unsupported DSL entry `$spec`. Expected a SteppableAlgorithm, ProcessState, or Function.")
    end
end

"""Resolve direct-call DSL syntax for either a `ProcessAlgorithm` or a plain Julia function."""
function _resolve_composite_dsl_call(
    spec,
    keyword_args::NamedTuple,
    positional_values::Tuple,
    output_symbols::Tuple{Vararg{Symbol}},
    routed_positional_inputs::Tuple,
    routed_keyword_inputs::Tuple,
    ::Val{Name},
) where {Name}
    if spec isa Union{ProcessAlgorithm, Type{<:ProcessAlgorithm}}
        all(input -> input.kind == :simple && input.source == input.destination, routed_positional_inputs) || error("Direct-call DSL syntax for ProcessAlgorithms only supports routed symbol positional arguments.")
        input_symbols = tuple((input.source for input in routed_positional_inputs)...)
        remapped_kwargs = Pair{Symbol, Symbol}[]
        for destination in keys(keyword_args)
            source = getproperty(keyword_args, destination)
            routed = findfirst(input -> input.destination == destination, routed_keyword_inputs)
            if isnothing(routed)
                source isa Symbol || error("Direct-call DSL syntax for ProcessAlgorithms only supports routed symbol keyword arguments.")
                push!(remapped_kwargs, destination => source)
                continue
            end

            input = routed_keyword_inputs[routed]
            input.kind == :simple || error("Direct-call DSL syntax for ProcessAlgorithms does not accept transformed or context-based keyword routing. Use `Algo(name = source)` route syntax instead.")
            push!(remapped_kwargs, destination => input.source)
        end

        return _resolve_composite_dsl_algorithm_call(spec, (; remapped_kwargs...), input_symbols, Val(Name))
    end

    spec isa Function || error("Direct-call DSL syntax requires either a plain function or a ProcessAlgorithm. Got `$spec`.")

    # FuncWrapper handles the runtime call; the DSL only has to recover how the
    # wrapper should receive its routed inputs.
    wrapped = FuncWrapper(spec, positional_values, output_symbols, keyword_args)
    resolved = _dsl_with_customname(wrapped, Val(Name))

    inputs = Any[routed_positional_inputs...]
    append!(inputs, routed_keyword_inputs)
    routed_inputs = tuple(inputs...)
    return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
end

"""Resolve keyword-only DSL call syntax at runtime without macro-time type inspection."""
function _resolve_composite_dsl_keyword_call(
    spec,
    keyword_args::NamedTuple,
    routed_inputs::Tuple,
    output_symbols::Tuple{Vararg{Symbol}},
    ::Val{Name},
) where {Name}
    if spec isa Function
        wrapped = FuncWrapper(spec, (), output_symbols, keyword_args)
        resolved = _dsl_with_customname(wrapped, Val(Name))
        return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
    end

    return _resolve_composite_dsl_entity(spec, routed_inputs, output_symbols, Val(Name))
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

"""Rewrite DSL alias references inside expressions while preserving routed symbols."""
function _dsl_rewrite_alias_expr(alias_map, ex, protected_symbols::Set{Symbol})
    if ex isa Symbol
        if ex in protected_symbols || !haskey(alias_map, ex)
            return ex
        end
        return alias_map[ex]
    elseif ex isa Expr
        if ex.head == :kw
            return Expr(:kw, ex.args[1], _dsl_rewrite_alias_expr(alias_map, ex.args[2], protected_symbols))
        elseif ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
            return Expr(:., _dsl_rewrite_alias_expr(alias_map, ex.args[1], protected_symbols), ex.args[2])
        end
        return Expr(ex.head, map(arg -> _dsl_rewrite_alias_expr(alias_map, arg, protected_symbols), ex.args)...)
    end
    return ex
end

"""
Strip DSL-only wrappers from the right-hand side of `@context`.

`@context` names the underlying algorithm expression, not its schedule wrapper,
so forms like `@context c = plus()`, `@context c = @repeat 2 plus()`, and
`@context c = @interval 3 plus()` all bind `c` to the same underlying `plus`
expression.
"""
function _dsl_normalize_context_binding(ex)
    if ex isa Expr
        if ex.head == :call && length(ex.args) == 1
            return _dsl_normalize_context_binding(ex.args[1])
        elseif ex.head == :macrocall && ex.args[1] in (Symbol("@repeat"), Symbol("@every"), Symbol("@interval"))
            length(ex.args) == 4 || error("Scheduling wrappers inside `@context` must use `@repeat n expr`, `@every n expr`, or `@interval n expr`.")
            return _dsl_normalize_context_binding(ex.args[4])
        end
    end
    return ex
end

"""
Parse one `@context name = algo()` declaration.

The right-hand side is normalized by stripping empty call syntax and any outer
DSL scheduling wrapper before the alias is recorded.
"""
function _dsl_parse_context(stmt)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@context") || error("Invalid @context statement `$stmt`.")
    length(stmt.args) == 3 || error("@context expects a single assignment like `@context c = plus()`.")
    assign = stmt.args[3]
    assign isa Expr && assign.head == :(=) || error("@context expects a single assignment like `@context c = plus()`.")
    lhs = assign.args[1]
    lhs isa Symbol || error("@context names must be symbols. Got `$lhs`.")
    return lhs => _dsl_normalize_context_binding(assign.args[2])
end

"""Rewrite the root of a dotted/ref expression if it starts from a context alias."""
function _dsl_rewrite_context_root(context_map, ex)
    if ex isa Symbol
        return get(context_map, ex, ex), haskey(context_map, ex)
    elseif ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        rewritten_base, changed = _dsl_rewrite_context_root(context_map, ex.args[1])
        return changed ? Expr(:., rewritten_base, ex.args[2]) : ex, changed
    elseif ex isa Expr && ex.head == :ref && !isempty(ex.args)
        rewritten_base, changed = _dsl_rewrite_context_root(context_map, ex.args[1])
        return changed ? Expr(:ref, rewritten_base, ex.args[2:end]...) : ex, changed
    end
    return ex, false
end

"""Extract a lowered route owner/source pair from a `@context` reference."""
function _dsl_parse_context_route_expr(context_map, ex)
    if ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        source = ex.args[2].value
        source isa Symbol || return nothing
        if ex.args[1] isa Symbol && haskey(context_map, ex.args[1])
            owner = Expr(:., context_map[ex.args[1]], QuoteNode(:_state))
            return (; owner, source)
        end
        owner, changed = _dsl_rewrite_context_root(context_map, ex.args[1])
        return changed ? (; owner, source) : nothing
    end
    return nothing
end

"""Rewrite the root of a dotted/ref expression if it starts from a known alias."""
function _dsl_rewrite_alias_owner_root(alias_map, ex)
    if ex isa Symbol
        binding = _dsl_alias_binding(alias_map, ex)
        isnothing(binding) && return ex, false
        return _dsl_known_owner_expr(binding.value, binding.name), true
    elseif ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        rewritten_base, changed = _dsl_rewrite_alias_owner_root(alias_map, ex.args[1])
        return changed ? Expr(:., rewritten_base, ex.args[2]) : ex, changed
    elseif ex isa Expr && ex.head == :ref && !isempty(ex.args)
        rewritten_base, changed = _dsl_rewrite_alias_owner_root(alias_map, ex.args[1])
        return changed ? Expr(:ref, rewritten_base, ex.args[2:end]...) : ex, changed
    end
    return ex, false
end

"""Extract a lowered route owner/source pair from a known alias field reference."""
function _dsl_parse_alias_route_expr(alias_map, ex)
    if ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        source = ex.args[2].value
        source isa Symbol || return nothing
        owner, changed = _dsl_rewrite_alias_owner_root(alias_map, ex.args[1])
        return changed ? (; owner, source) : nothing
    end
    return nothing
end

"""Extract a lowered route owner/source pair from a known alias or `@context` field reference."""
function _dsl_parse_owned_route_expr(alias_map, context_map, ex)
    parsed = _dsl_parse_context_route_expr(context_map, ex)
    isnothing(parsed) || return parsed
    return _dsl_parse_alias_route_expr(alias_map, ex)
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
        elseif spec.kind == :context_simple
            :( (; kind = :context_simple, owner = $(esc(spec.owner)), source = $(QuoteNode(spec.source)), destination = $(QuoteNode(spec.destination)) ) )
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
        elseif input.kind == :context_simple
            push!(options, Route(input.owner => target, input.source => input.destination))
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

"""Remember which symbols belong to an inline state for later writeback routing."""
function _composite_dsl_register_state_outputs!(state_owners::Dict{Symbol, Any}, owner, outputs::Tuple{Vararg{Symbol}})
    for output in outputs
        state_owners[output] = owner
    end
    return state_owners
end

"""
Bind the outputs produced by one DSL statement.

If the output already belongs to an inline `@state`, keep that state as the
owner and add a writeback route instead of rebinding the symbol.
"""
function _composite_dsl_bind_outputs!(options::Vector{Any}, producers::Dict{Symbol, Any}, state_owners::Dict{Symbol, Any}, target, outputs::Tuple{Vararg{Symbol}})
    for output in outputs
        if haskey(state_owners, output)
            push!(options, Route(state_owners[output] => target, output => output))
            producers[output] = state_owners[output]
        else
            producers[output] = target
        end
    end
    return producers
end

"""
Wrap an entity in a keyed owner when the DSL already knows its final name.

Internal rule: known alias/state keys should be preferred over raw values in
emitted route/share ownership metadata, because those keyed endpoints can later
be renamed during composition.
"""
function _dsl_known_owner_expr(entity_expr, name::Symbol)
    name == Symbol() && return entity_expr
    return :(Processes.IdentifiableAlgo($entity_expr, $(QuoteNode(name))))
end

"""Build the general state expression used by both `@state` and the block DSL."""
function _dsl_expand_state_expr(fields)
    field_names = Expr(:tuple, [QuoteNode(field.name) for field in fields]...)
    required_names = Expr(:tuple, [QuoteNode(field.name) for field in fields if field.required]...)
    default_kws = [Expr(:kw, field.name, esc(field.default)) for field in fields if !field.required]
    defaults_expr = Expr(:tuple, Expr(:parameters, default_kws...))

    return quote
        # The field metadata is kept in the type, while defaults are rebuilt on
        # each init call through the stored scheme closure.
        Processes.GeneralState(() -> $defaults_expr, Val{$field_names}(), Val{$required_names}())
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
    state_owner_expr = _dsl_known_owner_expr(:(_dsl_state), state_name)
    return quote
        local _dsl_state = $state_expr
        push!(_dsl_states, $(QuoteNode(state_name)) => _dsl_state)
        local _dsl_state_owner = $state_owner_expr
        Processes._composite_dsl_register_outputs!(_dsl_producers, _dsl_state_owner, $outputs_expr)
        Processes._composite_dsl_register_state_outputs!(_dsl_state_owners, _dsl_state_owner, $outputs_expr)
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

The alias name must be a plain symbol. Alias resolution is plain root
substitution inside the DSL: later `name` refers to the aliased expression, and
`name(args...)` rewrites to the aliased expression called with those arguments.
Only later uses of the alias name are rewritten. Writing the raw aliased
expression directly does not preserve the alias key.
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

"""
Parse a plain Julia function call DSL entry.

Supported function-call forms:
- `f(x)`
- `f(x, y)`
- `f("prefix", x)`
- `f(:name, x)`
- `f(x; scale = 2)`
- `f(x, y; scale = 2, offset = bias)`

Positional arguments may be routed symbols, quoted symbol literals, or ordinary
Julia expressions captured inline into the wrapper. Keyword values may be routed
from previous DSL outputs/@context references or captured as normal Julia
expressions.
"""
function _dsl_parse_function_positional_arg(alias_map, context_map, arg, known_outputs::Set{Symbol}, index::Int)
    if arg isa Symbol && (arg in known_outputs)
        return (; kind = :routed, value = arg), (; kind = :simple, source = arg, destination = arg)
    elseif arg isa QuoteNode && arg.value isa Symbol
        return (; kind = :literal_symbol, value = arg.value), nothing
    end

    owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, arg)
    if !isnothing(owned_route)
        routed_name = gensym(Symbol(:dsl_pos_, index))
        routed_input = (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination = routed_name)
        return (; kind = :routed, value = routed_name), routed_input
    end

    protected_symbols = Set(known_outputs)
    rewritten = _dsl_rewrite_alias_expr(alias_map, arg, protected_symbols)
    return (; kind = :captured, value = rewritten), nothing
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
            push!(keyword_specs, (; name, routed = true, value = name))
            return
        end

        owned_route = value isa Symbol ? nothing : _dsl_parse_owned_route_expr(alias_map, context_map, value)
        if !isnothing(owned_route)
            push!(routed_keyword_inputs, (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination = name))
            push!(keyword_specs, (; name, routed = true, value = name))
            return
        end

        protected_symbols = Set(known_outputs)
        rewritten = _dsl_rewrite_alias_expr(alias_map, value, protected_symbols)
        routed_symbols = Symbol[]
        _dsl_collect_transform_symbols!(routed_symbols, rewritten)
        filter!(in(known_outputs), routed_symbols)
        if !isempty(routed_symbols)
            routed_tuple = tuple(routed_symbols...)
            transform_expr = _dsl_transform_lambda_expr(rewritten, routed_tuple)
            push!(routed_keyword_inputs, (; kind = :transform, sources = routed_tuple, destination = name, transform_expr))
            push!(keyword_specs, (; name, routed = true, value = name))
        else
            push!(keyword_specs, (; name, routed = false, value = rewritten))
        end
    end

    positional_index = 0
    for arg in ex.args[2:end]
        if arg isa Expr && arg.head == :kw
            name = arg.args[1]
            name isa Symbol || error("Function keyword names must be symbols. Got `$name`.")
            _record_function_kwarg!(name, arg.args[2])
        elseif arg isa Expr && arg.head == :parameters
            for kw in arg.args
                kw isa Expr && kw.head == :kw || error("Invalid keyword argument `$kw` in DSL function call.")
                name = kw.args[1]
                name isa Symbol || error("Function keyword names must be symbols. Got `$name`.")
                _record_function_kwarg!(name, kw.args[2])
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

"""Emit a plain `NamedTuple` constructor for function-call keyword forwarding."""
function _dsl_function_keyword_args_expr(keyword_specs)
    kw_exprs = map(keyword_specs) do spec
        value_expr = spec.routed ? QuoteNode(spec.value) : esc(spec.value)
        Expr(:kw, spec.name, value_expr)
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
source in `IdentifiableAlgo`, because `@all(...)` is just syntax for a normal
`Share(raw_source, raw_target)` option. Runtime registration/matching is
responsible for comparing that raw source against any keyed identity later.
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
- `target = produced + other`
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

"""
Parse ProcessAlgorithm keyword routes.

Simple symbol values become normal routes. Expressions become transformed routes,
using any already-known DSL outputs as routed inputs and leaving the rest of the
expression captured normally.
"""
function _dsl_split_route_kwargs(alias_map, context_map, kwargs, known_outputs::Set{Symbol})
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

        owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, source)
        if !isnothing(owned_route)
            push!(inputs, (; kind = :context_simple, owner = owned_route.owner, source = owned_route.source, destination))
            continue
        end

        protected_symbols = Set(known_outputs)
        source = _dsl_rewrite_alias_expr(alias_map, source, protected_symbols)

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
function _dsl_parse_invocation(alias_map, context_map, ex, known_outputs::Set{Symbol})
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

"""
Emit the share/route owner expression matching the eventual constructor entry.

When the DSL already knows a stable alias/key, use that keyed wrapper directly so
later composition/renaming can update the reference without relying on raw-value
matching. Otherwise fall back to the raw entity and let constructor-time naming
resolve it later.
"""
function _dsl_share_endpoint_expr(alias_name::Symbol)
    _dsl_known_owner_expr(:(_dsl_resolved.entity), alias_name)
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
function _dsl_build_statement(stmt, alias_map, context_map, known_outputs::Set{Symbol}, expected_schedule::Symbol, owner_name::Symbol)
    if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@alias")
        return nothing
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@context")
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

    owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, rhs)
    if !isnothing(owned_route)
        length(outputs) == 1 || error("Owned field references like `alias.field` can only bind to one output symbol, e.g. `state = dynamics.state`.")
        output = only(outputs)
        output == owned_route.source || error("Owned field aliasing currently requires the output name to match the field name. Use `$(owned_route.source) = ...` for `$(repr(rhs))`.")
        return quote
            local _dsl_output = $(QuoteNode(output))
            local _dsl_owner = $(esc(owned_route.owner))
            if haskey(_dsl_state_owners, _dsl_output)
                push!(_dsl_options, Route(_dsl_owner => _dsl_state_owners[_dsl_output], _dsl_output => _dsl_output))
                _dsl_producers[_dsl_output] = _dsl_state_owners[_dsl_output]
            else
                _dsl_producers[_dsl_output] = _dsl_owner
            end
        end
    end

    parsed = _dsl_parse_invocation(alias_map, context_map, rhs, known_outputs)
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
            local _dsl_owner = $share_target_expr
            if _dsl_resolved isa Processes._CompositeDSLResolved{:state}
                # Inline states are stored separately and claim ownership of
                # their outputs immediately.
                push!(_dsl_states, _dsl_resolved.entity)
                Processes._composite_dsl_register_outputs!(_dsl_producers, _dsl_owner, _dsl_outputs)
            else
                # Algorithms are appended to the constructor argument list and
                # then wired into the routing tables.
                push!(_dsl_algos, $algo_entry_expr)
                push!(_dsl_specification, Int($schedule_expr))
                $(map(parsed.shares) do share_source
                    :(push!(_dsl_options, Processes.Share($(share_source), _dsl_owner)))
                end...)
                Processes._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
                Processes._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
            end
        end
    end

    if parsed.kind == :resolved_expr
        algo_entry_expr = _dsl_algorithm_entry_expr(parsed.alias_name)
        owner_expr = _dsl_share_endpoint_expr(parsed.alias_name)
        return quote
            local _dsl_outputs = $outputs_expr
            # Repeated inner blocks already expand to one resolved entity, so the
            # outer builder only has to wire and register them.
            local _dsl_resolved = $(parsed.resolved_expr)
            local _dsl_owner = $owner_expr
            push!(_dsl_algos, $algo_entry_expr)
            push!(_dsl_specification, Int($schedule_expr))
            Processes._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
            Processes._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
        end
    end

    positional_values_expr = _dsl_function_positional_args_expr(parsed.positional_specs)
    routed_positional_inputs_expr = _dsl_inputs_expr(parsed.routed_positional_inputs)
    keyword_args_expr = _dsl_function_keyword_args_expr(parsed.keyword_specs)
    inputs_expr = _dsl_inputs_expr(parsed.inputs)
    customname = _dsl_customname(parsed.spec_expr, parsed.alias_name)
    algo_entry_expr = _dsl_algorithm_entry_expr(parsed.alias_name)
    share_target_expr = _dsl_share_endpoint_expr(parsed.alias_name)

    if parsed.kind == :keyword_call
        return quote
            local _dsl_outputs = $outputs_expr
            local _dsl_resolved = Processes._resolve_composite_dsl_keyword_call(
                $(esc(parsed.spec_expr)),
                $keyword_args_expr,
                $inputs_expr,
                _dsl_outputs,
                Val{$(QuoteNode(customname))}(),
            )
            local _dsl_owner = $share_target_expr
            push!(_dsl_algos, $algo_entry_expr)
            push!(_dsl_specification, Int($schedule_expr))
            $(map(parsed.shares) do share_source
                :(push!(_dsl_options, Processes.Share($(share_source), _dsl_owner)))
            end...)
            Processes._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
            Processes._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
        end
    end

    return quote
        local _dsl_outputs = $outputs_expr
        # Function-call syntax stays on a dedicated path so we can recover
        # positional inputs and keyword captures for `FuncWrapper`.
        local _dsl_resolved = Processes._resolve_composite_dsl_call(
            $(esc(parsed.spec_expr)),
            $keyword_args_expr,
            $positional_values_expr,
            _dsl_outputs,
            $routed_positional_inputs_expr,
            $inputs_expr,
            Val{$(QuoteNode(customname))}(),
        )
        local _dsl_owner = $share_target_expr
        push!(_dsl_algos, $algo_entry_expr)
        push!(_dsl_specification, Int($schedule_expr))
        Processes._composite_dsl_add_routes!(_dsl_options, _dsl_producers, _dsl_external_inputs, _dsl_owner, _dsl_resolved.inputs)
        Processes._composite_dsl_bind_outputs!(_dsl_options, _dsl_producers, _dsl_state_owners, _dsl_owner, _dsl_outputs)
    end
end

"""
Walk a DSL block once and collect the state declarations plus executable statements.

This is shared by the top-level `@CompositeAlgorithm`/`@Routine` expansion and the
inner `@repeat n begin ... end` block expansion so they stay in sync.
"""
function _dsl_collect_block(statements, expected_schedule::Symbol, owner_name::Symbol)
    alias_map = Dict{Symbol, Any}()
    context_map = Dict{Symbol, Any}()
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
        elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@context")
            context = _dsl_parse_context(stmt)
            alias_map[context.first] = context.second
            context_map[context.first] = context.second
            step_expr = _dsl_build_statement(stmt.args[3].args[2], alias_map, context_map, known_outputs, expected_schedule, owner_name)
            isnothing(step_expr) || push!(step_exprs, step_expr)
            continue
        end

        step_expr = _dsl_build_statement(stmt, alias_map, context_map, known_outputs, expected_schedule, owner_name)
        isnothing(step_expr) || push!(step_exprs, step_expr)
        # Outputs become available to the statements that follow them.
        _dsl_known_outputs!(known_outputs, stmt)
    end

    return (; step_exprs, state_fields, state_name)
end

"""Create a `GeneralState` value directly."""
macro state(args...)
    fields = _dsl_collect_state_fields(args)
    return _dsl_expand_state_expr(fields)
end

"""Expand a top-level DSL block into either a `CompositeAlgorithm` or a `Routine`."""
function _dsl_expand_loopalgorithm(block, constructor_name::Symbol, expected_schedule::Symbol; print_constructor::Bool = false)
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
            local _dsl_state_owners = Dict{Symbol, Any}()
            local _dsl_external_inputs = Pair{Symbol, Symbol}[]

            $(isnothing(state_setup_expr) ? nothing : state_setup_expr)
            $(collected.step_exprs...)

            isempty(_dsl_algos) && error("`@$constructor_name` requires at least one algorithm entry.")
            $(print_constructor ? :(Processes._dsl_print_constructor_call($(QuoteNode(constructor_name)), _dsl_algos, _dsl_specification, _dsl_states, _dsl_options)) : nothing)
            # Build the final `CompositeAlgorithm`/`Routine` using the same
            # constructor surface users would write by hand.
            getproperty(Processes, $(QuoteNode(constructor_name)))(_dsl_algos..., Tuple(_dsl_specification), _dsl_states..., _dsl_options...)
        end
    end
end

"""Print the final loop-algorithm constructor call assembled by the DSL."""
function _dsl_print_constructor_call(constructor_name::Symbol, algos, specification, states, options)
    args = Any[algos..., Tuple(specification), states..., options...]
    println(string(constructor_name, "(", join(repr.(args), ", "), ")"))
    return nothing
end

"""Parse optional macro flags for `@CompositeAlgorithm` and `@Routine`."""
function _dsl_parse_loopalgorithm_macro_args(args, macro_name::Symbol)
    if length(args) == 1
        return (; block = args[1], print_constructor = false)
    elseif length(args) == 2
        flag = args[1]
        is_print = flag == :print || (flag isa QuoteNode && flag.value == :print)
        is_print || error("`@$macro_name` only supports the optional `:print` flag before the block.")
        return (; block = args[2], print_constructor = true)
    end
    error("`@$macro_name` expects either `@$macro_name begin ... end` or `@$macro_name :print begin ... end`.")
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
            local _dsl_state_owners = Dict{Symbol, Any}()
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

Aliases only affect later uses of the alias name itself. For example,
`@alias dynamics = Metropolis()` only contributes the key `:dynamics` when a
later statement actually uses `dynamics(...)`; writing `Metropolis(...)`
directly emits an unaliased `Metropolis` entry.

Plain entries:
- `Algo`
- `Algo()`
- `alias`
- `alias()`
- `alias(args...)`

Assignments:
- `x = Algo`
- `x = Algo()`
- `x = alias`
- `x = alias()`
- `x = alias(args...)`
- `a, b = Algo(...)`

ProcessAlgorithm routes:
- `x = Algo(input = produced)`
- `x = Algo(left = a, right = b)`
- `x = Algo(value = produced * 2)`
- `x = Algo(value = produced + passthrough + bias)`
- `x = SomeAlgo(args...)(input = produced)`
- `x = alias(input = produced)`
- `x = alias(args...)(input = produced)`

Plain-function entries:
- `x = f(produced)`
- `x = f(produced, other)`
- `x = f(produced; scale = 2)`
- `x = f(produced; scale = factor)`

Context aliases:
- `@context c = algo()`
- `@context c = @repeat n algo()`
- `@context c = Algo(args...)`
- `x = f(value = c.seed)`
- `x = f(value = c.subalgo.buffer)`
- `x = f(value = c[subalgo].buffer)`
- `consumer(input = dynamics.state)`
- `value = f(dynamics.state)`
- `consumer(input = c1.plus_capture.captured)`
- `state = dynamics.state`

`@context` is only a macro-time alias for later references. The executable DSL
statement is still built from the original right-hand side expression, so
`@context c = @repeat 2 capture_noise()` runs `capture_noise()` on that schedule
but does not assign the nested algorithm the key `:c`.

Direct `c.field` access is interpreted as a reference to the nested inline
state owned by that algorithm, so `n.changeable_seed` lowers like routing from
`capture_noise._state` with source `:changeable_seed`.

Direct owned-field access like `dynamics.state` is also accepted in route
positions. It routes directly from the known `:dynamics` owner with source
`:state`, even if no earlier statement bound `state = dynamics()`. The special
binding form `state = dynamics.state` exposes that same owned field under the
plain DSL output name `state` for later statements.

Full-context shares:
- `Algo(@all(source))`
- `Algo(@all(alias...))`

`@all(...)` lowers to a normal `Share(raw_source, raw_target)` option. The DSL
does not manufacture `IdentifiableAlgo` wrappers for either endpoint; keyed
matching is left to the normal runtime registration logic.

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

Debug output
============

- `@CompositeAlgorithm :print begin ... end`

prints the final `CompositeAlgorithm(...)` constructor call assembled by the DSL
before it is executed.
"""
macro CompositeAlgorithm(args...)
    parsed = _dsl_parse_loopalgorithm_macro_args(args, :CompositeAlgorithm)
    _dsl_expand_loopalgorithm(parsed.block, :CompositeAlgorithm, :every; print_constructor = parsed.print_constructor)
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
- `@context c = @repeat 2 algo()`
- `Damper(@all(osc...))`
- `PickRandomSeed(targetseed = n.changeable_seed)`
- `@Routine :print begin ... end`
"""
macro Routine(args...)
    parsed = _dsl_parse_loopalgorithm_macro_args(args, :Routine)
    _dsl_expand_loopalgorithm(parsed.block, :Routine, :repeat; print_constructor = parsed.print_constructor)
end
