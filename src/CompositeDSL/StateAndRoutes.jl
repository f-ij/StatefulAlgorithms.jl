"""Track which output symbols are available to later route expressions in the same DSL block."""
function _dsl_known_outputs!(known_outputs::Set{Symbol}, stmt)
    if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
        _, fields = _dsl_parse_state_statement(stmt)
        union!(known_outputs, getproperty.(fields, :name))
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@input")
        push!(known_outputs, _dsl_parse_input_statement(stmt).name)
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@include_if")
        _, include_body = _dsl_parse_include_if(stmt)
        _dsl_known_outputs_include_body!(known_outputs, include_body)
    elseif stmt isa Expr && stmt.head == :(=)
        outputs = _dsl_try_parse_output_symbols(stmt.args[1])
        isnothing(outputs) || union!(known_outputs, outputs)
    end
    return known_outputs
end

"""Track outputs from an `@include_if` body for later route parsing."""
function _dsl_known_outputs_include_body!(known_outputs::Set{Symbol}, include_body)
    statements = include_body isa Expr && include_body.head == :block ? include_body.args : Any[include_body]
    for stmt in statements
        stmt isa LineNumberNode && continue
        _dsl_known_outputs!(known_outputs, stmt)
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
        elseif spec.kind == :simple_transform
            :( (; kind = :simple_transform, source = $(QuoteNode(spec.source)), destination = $(QuoteNode(spec.destination)), transform = $(esc(spec.transform_expr)) ) )
        elseif spec.kind == :context_transform
            :( (; kind = :context_transform, owner = $(esc(spec.owner)), source = $(QuoteNode(spec.source)), destination = $(QuoteNode(spec.destination)), transform = $(esc(spec.transform_expr)) ) )
        else
            error("Unsupported DSL input spec kind `$(spec.kind)`.")
        end
    end
    return Expr(:tuple, specs...)
end

"""Emit keyword values for direct-call DSL syntax."""
_dsl_keyword_value_expr(value) = value isa Symbol ? QuoteNode(value) : esc(value)

"""Store a DSL-emitted plan option at the statement-local owner."""
function _composite_dsl_push_local_option!(options::Vector{Any}, owner, option)
    @nospecialize owner option
    push!(options, LocalPlanOption(owner, option))
    return options
end

"""Turn parsed DSL input specs into statement-local `Route` options."""
function _composite_dsl_add_routes!(options::Vector{Any}, producers::Dict{Symbol, Any}, external_inputs::Vector{Pair{Symbol, Symbol}}, target, inputs::Tuple)
    @nospecialize target inputs
    for input in inputs
        if input.kind == :simple
            source = input.source
            destination = input.destination
            if haskey(producers, source)
                _composite_dsl_push_local_option!(options, target, Route(producers[source] => target, source => destination))
            else
                ext_mapping = source => source
                ext_mapping in external_inputs || push!(external_inputs, ext_mapping)
            end
        elseif input.kind == :context_simple
            _composite_dsl_push_local_option!(options, target, Route(input.owner => target, input.source => input.destination))
        elseif input.kind == :simple_transform
            source = input.source
            haskey(producers, source) || error("Transform routes currently require a previously produced symbol or an owned field reference. Missing producer for `$source`.")
            _composite_dsl_push_local_option!(options, target, Route(producers[source] => target, source => input.destination; transform = input.transform))
        elseif input.kind == :context_transform
            _composite_dsl_push_local_option!(options, target, Route(input.owner => target, input.source => input.destination; transform = input.transform))
        else
            error("Unsupported DSL input kind `$(input.kind)`.")
        end
    end
    return options
end

"""Return whether a DSL owner writes its outputs into runtime globals."""
@inline _composite_dsl_runtime_owner(owner::FuncWrapper) = true
@inline _composite_dsl_runtime_owner(owner::AbstractIdentifiableAlgo{<:FuncWrapper}) = true
@inline _composite_dsl_runtime_owner(owner) = false

"""Register outputs as the current producer for later routed lookups."""
function _composite_dsl_register_outputs!(producers::Dict{Symbol, Any}, owner, outputs::Tuple{Vararg{Symbol}})
    @nospecialize owner outputs
    owner = _composite_dsl_runtime_owner(owner) ? :_runtime : owner
    for output in outputs
        # Later statements resolve symbols by asking this table who currently
        # owns a given output name.
        producers[output] = owner
    end
    return producers
end

"""Remember which symbols belong to an inline state for later writeback routing."""
function _composite_dsl_register_state_outputs!(state_owners::Dict{Symbol, Any}, owner, outputs::Tuple{Vararg{Symbol}})
    @nospecialize owner outputs
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
    @nospecialize target outputs
    if _composite_dsl_runtime_owner(target)
        _composite_dsl_register_outputs!(producers, :_runtime, outputs)
        return producers
    end

    for output in outputs
        if haskey(state_owners, output)
            _composite_dsl_push_local_option!(options, target, Route(state_owners[output] => target, output => output))
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
function _composite_dsl_owner(entity, name::Symbol)
    if entity isa AbstractLoopAlgorithm
        return entity
    end
    return IdentifiableAlgo(entity, name)
end

"""Return the constructor entry used for a DSL algorithm/state value.

`CompositeAlgorithm`/`Routine` constructors accept `:name => entity` pairs for
normal process entities, but nested loop algorithms are already keyed through
their own tree. This helper centralizes that distinction so route ownership and
constructor entries keep the same identity convention.
"""
function _composite_dsl_entry(entity, name::Symbol)
    if name == Symbol() || entity isa AbstractLoopAlgorithm
        return entity
    end
    return name => entity
end

"""Emit an expression for the owner value associated with a known DSL name.

The DSL builds route/share metadata at macro expansion time, but the concrete
entity is only available when the emitted block runs. This helper returns the
runtime expression that wraps the entity in `IdentifiableAlgo` when a stable DSL
name is known, and leaves it unchanged when no name was declared.
"""
function _dsl_known_owner_expr(entity_expr, name::Symbol)
    name == Symbol() && return entity_expr
    return :(StatefulAlgorithms._composite_dsl_owner($entity_expr, $(QuoteNode(name))))
end

"""Return the key-safe owner value used by `Var` selectors emitted from the DSL."""
function _composite_dsl_var_owner(owner::O) where {O}
    if owner isa AbstractIdentifiableAlgo && haskey(owner)
        return getkey(owner)
    end
    return owner
end

"""Resolve a DSL variable name to the `Var` selector for its current producer."""
function _composite_dsl_var_selector(producers::D, current_owner::O, current_outputs::CO, name::Symbol) where {D<:Dict{Symbol,Any},O,CO<:Tuple}
    if name in current_outputs
        isnothing(current_owner) && error("Cannot use current output `$name` as a lifetime selector here.")
        return Var(_composite_dsl_var_owner(current_owner), name)
    elseif haskey(producers, name)
        return Var(_composite_dsl_var_owner(producers[name]), name)
    end
    error("Lifetime selector `$name` is not a known DSL variable at this point.")
end

"""Return the route target used for `owner.field = value` DSL writes.

Loop algorithms expose their inline state through the synthetic `._state`
property, so writes into a nested routine/composite must target that state owner.
Plain algorithms use the normal keyed owner wrapper.
"""
function _composite_dsl_write_owner(entity, name::Symbol)
    if entity isa AbstractLoopAlgorithm
        return getproperty(entity, :_state)
    end
    return IdentifiableAlgo(entity, name)
end

"""Return the key carried by a state constructor entry.

State entries appear in several forms while the DSL is being assembled:
`:_state => state` before constructor parsing, `IdentifiableAlgo(state, key)`
after parsing/resolution, and occasionally a plain state value in lower-level
helpers. This accessor lets the approval code handle those shapes uniformly.
"""
@inline _composite_dsl_state_entry_key(entry::P) where {P<:Pair} = entry.first
@inline _composite_dsl_state_entry_key(entry::IA) where {IA<:AbstractIdentifiableAlgo} = getkey(entry)
@inline _composite_dsl_state_entry_key(entry::E) where {E} = Symbol()

"""Return the process state value contained by a state constructor entry."""
@inline _composite_dsl_state_entry_value(entry::P) where {P<:Pair} = entry.second
@inline _composite_dsl_state_entry_value(entry::IA) where {IA<:AbstractIdentifiableAlgo} = getalgo(entry)
@inline _composite_dsl_state_entry_value(entry::E) where {E} = entry

"""Rebuild a state constructor entry after transforming the contained state.

This preserves the original entry wrapper. For example, a `:_state => state`
input stays a pair, while an already resolved `IdentifiableAlgo` keeps its key,
id, aliases, and algorithm name.
"""
function _composite_dsl_rebuild_state_entry(entry::P, state::S) where {P<:Pair, S}
    return entry.first => state
end

function _composite_dsl_rebuild_state_entry(entry::IA, state::S) where {IA<:AbstractIdentifiableAlgo, S}
    return setfield(entry, :func, state)
end

_composite_dsl_rebuild_state_entry(entry::E, state::S) where {E, S} = state

"""Apply `func` to one state constructor entry, preserving its wrapper.

The returned boolean tells callers whether the state object changed. That lets
the tree walk below return original branches unchanged when diagnostic metadata
does not apply.
"""
function _composite_dsl_map_state_entry(func::F, entry::E) where {F, E}
    state = _composite_dsl_state_entry_value(entry)
    next_state = func(state)
    next_state === state && return entry, false
    return _composite_dsl_rebuild_state_entry(entry, next_state), true
end

@inline _composite_dsl_map_state_entries(::F, entries::Tuple{}) where {F} = entries, false

"""Apply `func` to a tuple of state entries without rebuilding no-op tuples."""
function _composite_dsl_map_state_entries(func::F, entries::Entries) where {F, Entries<:Tuple}
    head, head_changed = _composite_dsl_map_state_entry(func, first(entries))
    tail, tail_changed = _composite_dsl_map_state_entries(func, Base.tail(entries))
    (head_changed || tail_changed) || return entries, false
    return (head, tail...), true
end

@inline _composite_dsl_map_state_children(::F, children::Tuple{}) where {F} = children, false

"""Apply a state transform through child algorithms without rebuilding no-op branches."""
function _composite_dsl_map_state_children(func::F, children::Children) where {F, Children<:Tuple}
    head, head_changed = _composite_dsl_map_states_changed(func, first(children))
    tail, tail_changed = _composite_dsl_map_state_children(func, Base.tail(children))
    (head_changed || tail_changed) || return children, false
    return (head, tail...), true
end

"""Apply `func` to every process state contained by a loop-algorithm tree.

The DSL needs to update state metadata before the parent constructor flattens
nested algorithms into one registry. This tree walk preserves the executable
plan shape and only replaces branches that contain a changed state. Non-loop
algorithm leaves pass through unchanged.
"""
function _composite_dsl_map_states_changed(func::F, entity::LA) where {F, LA<:LoopAlgorithm}
    plan, plan_changed = _composite_dsl_map_states_changed(func, getplan(entity))
    states, states_changed = _composite_dsl_map_state_entries(func, getstates(entity))
    (plan_changed || states_changed) || return entity, false
    return LoopAlgorithm(
        plan;
        states,
        options = getoptions(entity),
        registry = getregistry(entity),
        context = getstoredcontext(entity),
        inits = getstoredinits(entity),
        overrides = getstoredoverrides(entity),
        id = getid(entity),
    ), true
end

function _composite_dsl_map_states_changed(func::F, entity::LA) where {F, LA<:Union{CompositeAlgorithm, Routine}}
    funcs, funcs_changed = _composite_dsl_map_state_children(func, getalgos(entity))
    funcs_changed || return entity, false
    return rebuild_loopalgorithm_funcs(entity, funcs), true
end

function _composite_dsl_map_states_changed(func::F, entity::IA) where {F, Inner<:AbstractLoopAlgorithm, IA<:AbstractIdentifiableAlgo{Inner}}
    inner, inner_changed = _composite_dsl_map_states_changed(func, getalgo(entity))
    inner_changed || return entity, false
    return setfield(entity, :func, inner), true
end

_composite_dsl_map_states_changed(::F, entity::E) where {F, E} = entity, false

"""Return an entity with `func` applied to contained states."""
function _composite_dsl_map_states(func::F, entity::E) where {F, E}
    mapped, _ = _composite_dsl_map_states_changed(func, entity)
    return mapped
end

"""Prefix diagnostic state-field paths with a parent `@context` alias.

Warnings for overlapping anonymous `@state` fields are only useful when they
name where the fields came from. When a parent writes `@context f = child()`,
this changes diagnostic paths from `buffers` to `f.buffers` while leaving the
runtime field name as `:buffers`.
"""
function _composite_dsl_prefix_state_diagnostic_paths(entity::E, context_alias::Symbol) where {E}
    return _composite_dsl_map_states(entity) do state
        state isa GeneralState || return state
        return prefix_general_state_diagnostic_paths(state, context_alias)
    end
end

"""Mark a field in nested inline states as explicitly shared.

`@bind` and `@merge` do not create a new route by themselves; they mark a future
`GeneralState` merge as intentional so the registry can coalesce the slots
without emitting the accidental-overlap warning. The field name is still the
actual state variable name, not the display path.
"""
function _composite_dsl_mark_shared_state_field(entity::E, field::Symbol) where {E}
    return _composite_dsl_map_states(entity) do state
        state isa GeneralState || return state
        field in general_state_fields(state) || return state
        return mark_general_state_fields_explicitly_shared(state, (field,))
    end
end

"""Mark a shared field on the current block's anonymous inline state.

This is the current-block half of `@bind buffers => f.buffers`. The local state
has already been pushed into `_dsl_states` by `_dsl_state_setup_expr`, so the
metadata update mutates that constructor list before the final loop-algorithm
constructor call is made.
"""
function _composite_dsl_mark_local_shared_state_field!(states::S, field::Symbol) where {S<:Vector{Any}}
    for idx in eachindex(states)
        entry = states[idx]
        _composite_dsl_state_entry_key(entry) == :_state || continue
        state = _composite_dsl_state_entry_value(entry)
        state isa GeneralState || continue
        field in general_state_fields(state) || continue
        states[idx] = _composite_dsl_rebuild_state_entry(entry, mark_general_state_fields_explicitly_shared(state, (field,)))
    end
    return states
end

"""Mark a shared field on the child entry named by a `@context` alias.

The parent DSL records the index at which each `@context` entry was pushed into
`_dsl_algos`. `@bind`/`@merge` use that table to rewrite the already-pushed child
entry with explicit-sharing metadata. Referencing an unknown alias is a DSL
authoring error because state-sharing declarations must appear after the relevant
`@context` declaration.
"""
function _composite_dsl_mark_context_shared_state_field!(algos::A, context_indices::CI, context_alias::Symbol, field::Symbol) where {A<:Vector{Any}, CI<:Dict{Symbol, Int}}
    haskey(context_indices, context_alias) || error("`@bind`/`@merge` references unknown context alias `$context_alias`. Declare it first with `@context $context_alias = ...`.")
    idx = context_indices[context_alias]
    algos[idx] = _composite_dsl_mark_shared_state_field(algos[idx], field)
    return algos
end

"""Build the `GeneralState` constructor expression for parsed `@state` fields.

Required fields are stored in the `Required` type parameter, while defaulted
fields are emitted into a zero-argument builder closure. Keeping defaults in a
builder is important for mutable defaults such as `Float64[]`: each init gets a
fresh value instead of sharing one array across process instances.
"""
function _dsl_expand_state_expr(fields)
    field_names = Expr(:tuple, [QuoteNode(field.name) for field in fields]...)
    required_names = Expr(:tuple, [QuoteNode(field.name) for field in fields if field.required]...)
    default_kws = [Expr(:kw, field.name, esc(field.default)) for field in fields if !field.required]
    defaults_expr = Expr(:tuple, Expr(:parameters, default_kws...))

    return quote
        # The field metadata is kept in the type, while defaults are rebuilt on
        # each init call through the stored scheme closure.
        StatefulAlgorithms.GeneralState(() -> $defaults_expr, Val{$field_names}(), Val{$required_names}())
    end
end

"""Parse one field entry from a `@state` declaration.

Plain symbols become required state slots. Assignments become optional slots
whose right-hand side is evaluated by the generated defaults builder during
state initialization.
"""
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

"""Collect field entries from a `@state` declaration, ignoring line nodes.

The parser accepts both compact forms such as `@state x = 1` and block forms
such as `@state begin ... end`. This helper flattens those surface forms into a
single vector of raw field entries before per-field validation.
"""
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

The return value is `(state_name, fields)`. Anonymous state declarations use the
reserved state key `:_state`; named forms use the explicit state key supplied by
the user.
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

"""Parse one `@input` declaration into runtime-input metadata.

`@input x` declares a required input of type `Any`; `@input x::T` records a type
constraint; `@input x = default` makes the input optional. The result is a plain
NamedTuple so the macro collector can carry input metadata without constructing
runtime objects early.
"""
function _dsl_parse_input_entry(ex)
    default = nothing
    required = true
    lhs = ex
    if ex isa Expr && ex.head == :(=)
        lhs = ex.args[1]
        default = ex.args[2]
        required = false
    end
    name, typeexpr = if lhs isa Expr && lhs.head == :(::)
        lhs.args[1], lhs.args[2]
    else
        lhs, :Any
    end
    name isa Symbol || error("@input fields must be plain symbols or typed symbols. Got `$lhs`.")
    return (; name, typeexpr, required, default)
end

"""Parse a complete `@input` statement.

The current DSL deliberately allows exactly one input field per statement. That
keeps diagnostics precise and mirrors the runtime `RuntimeInput` objects emitted
later by `_dsl_runtime_input_setup_expr`.
"""
function _dsl_parse_input_statement(stmt)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@input") || error("Invalid @input statement `$stmt`.")
    args = [stmt.args[i] for i in 3:length(stmt.args) if !(stmt.args[i] isa LineNumberNode)]
    length(args) == 1 || error("@input expects one declaration, got `$args`.")
    return _dsl_parse_input_entry(only(args))
end

"""Accumulate one `@state` statement into the current block-level inline state.

One DSL block produces at most one inline `GeneralState` entry. Multiple
anonymous `@state` statements are merged into that entry, but mixing two
different explicit state names in one block is rejected because later plain field
references would become ambiguous.
"""
function _dsl_merge_state_statement!(state_fields::Vector, state_name::Symbol, stmt)
    this_state_name, this_state_fields = _dsl_parse_state_statement(stmt)
    state_name == :_state || this_state_name == :_state || this_state_name == state_name || error("Use a single state name inside one DSL block. Got `$state_name` and `$this_state_name`.")
    append!(state_fields, this_state_fields)
    return this_state_name == :_state ? state_name : this_state_name
end

"""Generate the emitted setup expression for the block's inline state.

The emitted code constructs the `GeneralState`, pushes it into `_dsl_states`, and
registers its fields as known producers/state owners. Registering state owners is
what lets later assignments such as `buffers = f(buffers)` route the produced
value back into the inline state slot instead of rebinding `buffers` to a new
algorithm owner.
"""
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
        StatefulAlgorithms._composite_dsl_register_outputs!(_dsl_producers, _dsl_state_owner, $outputs_expr)
        StatefulAlgorithms._composite_dsl_register_state_outputs!(_dsl_state_owners, _dsl_state_owner, $outputs_expr)
    end
end

"""Generate the emitted setup expression for collected `@input` fields.

Runtime inputs are represented as a special `RuntimeInputState` plus a matching
`RuntimeInputs` option. The state owns the input symbols for DSL routing
purposes, while the option performs validation/default handling when users call
`run(...; input = value)`.
"""
function _dsl_runtime_input_setup_expr(input_fields)
    isempty(input_fields) && return nothing
    specs = map(input_fields) do field
        :(StatefulAlgorithms.RuntimeInput($(QuoteNode(field.name)), $(esc(field.typeexpr)); required = $(field.required), default = $(field.required ? nothing : esc(field.default))))
    end
    outputs_expr = Expr(:tuple, [QuoteNode(field.name) for field in input_fields]...)
    return quote
        local _dsl_runtime_input_specs = ($(specs...),)
        local _dsl_input_state = StatefulAlgorithms.RuntimeInputState(_dsl_runtime_input_specs)
        push!(_dsl_states, :_input => _dsl_input_state)
        push!(_dsl_options, StatefulAlgorithms.RuntimeInputs(_dsl_runtime_input_specs))
        local _dsl_input_owner = StatefulAlgorithms._composite_dsl_owner(_dsl_input_state, :_input)
        StatefulAlgorithms._composite_dsl_register_outputs!(_dsl_producers, _dsl_input_owner, $outputs_expr)
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
    parsed = _dsl_try_parse_output_symbols(lhs)
    !isnothing(parsed) && return parsed
    error("Unsupported left-hand side in the DSL: `$lhs`.")
end

"""Try to parse assignment outputs without throwing.

Callers use this in speculative paths where an expression may not be a DSL
assignment. A single symbol becomes a one-element tuple; tuple LHS forms become
multi-output tuples; unsupported LHS forms return `nothing`.
"""
function _dsl_try_parse_output_symbols(lhs)
    if lhs isa Symbol
        return (lhs,)
    elseif lhs isa Expr && lhs.head == :tuple
        all(x -> x isa Symbol, lhs.args) || error("Multi-output bindings must use plain symbols like `a, b = algo`.")
        return tuple(lhs.args...)
    end
    return nothing
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

"""Parse a constructor-time conditional include statement.

`@include_if condition entry` and `@include_if condition begin ... end` are
evaluated while building the loop algorithm, not during process stepping. The
returned pair is the condition expression plus the entry/body expression to
lower when the condition is true.
"""
function _dsl_parse_include_if(stmt)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@include_if") || error("Invalid @include_if statement `$stmt`.")
    length(stmt.args) == 4 || error("@include_if expects `@include_if condition entry` or `@include_if condition begin ... end`.")
    return stmt.args[3], stmt.args[4]
end

"""Parse a root-level final post-processing statement.

`@finally` wraps the outer DSL algorithm in `FinalizedAlgorithm`. It is parsed
here but enforced by the block collector so nested and conditional uses can
produce targeted errors.
"""
function _dsl_parse_finally(stmt)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@finally") || error("Invalid @finally statement `$stmt`.")
    length(stmt.args) == 3 || error("@finally expects exactly one callable, e.g. `@finally summarize`.")
    return stmt.args[3]
end

"""Reject declarations whose scope would be ambiguous inside conditional blocks.

`@include_if` can conditionally add executable entries, but it cannot
conditionally introduce names, state slots, or state-sharing approvals. Those
declarations affect the surrounding block's compile-time routing tables and must
be visible unconditionally before later statements are parsed.
"""
function _dsl_reject_include_if_declarations(stmt)
    if stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@state")
        error("@state is not supported inside `@include_if`; declare state at the surrounding DSL block level.")
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@alias")
        error("@alias is not supported inside `@include_if`; declare aliases before the conditional block.")
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@bind")
        error("@bind is not supported inside `@include_if`; bind state at the surrounding DSL block level.")
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@merge")
        error("@merge is not supported inside `@include_if`; merge state at the surrounding DSL block level.")
    elseif stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@finally")
        error("@finally is root-only and is not supported inside `@include_if`.")
    end
    return nothing
end
