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
            :( (; kind = :simple, source_field = $(QuoteNode(spec.source_field)), target_field = $(QuoteNode(spec.target_field)) ) )
        elseif spec.kind == :context_simple
            :( (; kind = :context_simple, owner = $(esc(spec.owner)), source_field = $(QuoteNode(spec.source_field)), target_field = $(QuoteNode(spec.target_field)) ) )
        elseif spec.kind == :simple_transform
            :( (; kind = :simple_transform, source_field = $(QuoteNode(spec.source_field)), target_field = $(QuoteNode(spec.target_field)), transform = $(esc(spec.transform_expr)) ) )
        elseif spec.kind == :context_transform
            :( (; kind = :context_transform, owner = $(esc(spec.owner)), source_field = $(QuoteNode(spec.source_field)), target_field = $(QuoteNode(spec.target_field)), transform = $(esc(spec.transform_expr)) ) )
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
function _composite_dsl_add_routes!(options::Vector{Any}, producers::Dict{Symbol, Any}, external_inputs::Vector{Pair{Symbol, Symbol}}, target_owner, inputs::Tuple)
    @nospecialize target_owner inputs
    for input in inputs
        if input.kind == :simple
            source_field = input.source_field
            target_field = input.target_field
            if haskey(producers, source_field)
                _composite_dsl_push_local_option!(options, target_owner, Route(producers[source_field] => target_owner, source_field => target_field))
            else
                ext_mapping = source_field => source_field
                ext_mapping in external_inputs || push!(external_inputs, ext_mapping)
            end
        elseif input.kind == :context_simple
            _composite_dsl_push_local_option!(options, target_owner, Route(input.owner => target_owner, input.source_field => input.target_field))
        elseif input.kind == :simple_transform
            source_field = input.source_field
            haskey(producers, source_field) || error("Transform routes currently require a previously produced symbol or an owned field reference. Missing producer for `$source_field`.")
            _composite_dsl_push_local_option!(options, target_owner, Route(producers[source_field] => target_owner, source_field => input.target_field; transform = input.transform))
        elseif input.kind == :context_transform
            _composite_dsl_push_local_option!(options, target_owner, Route(input.owner => target_owner, input.source_field => input.target_field; transform = input.transform))
        else
            error("Unsupported DSL input kind `$(input.kind)`.")
        end
    end
    return options
end

"""
Wires for one DSL statement, attached to its position in the plan with `WithWiring`: what it reads, routed to its
arguments. For a call: reads from algorithm state (`owner.field`) and transforms; a plain name produced by an earlier
call, or a declared local, needs no wire, the call reads it by name from its scope. For a step algorithm: every
argument it is given. Wires belong to the statement, not to the algorithm: the same algorithm at two positions
(`AddOne!(y)`, `AddOne!(x)`) shares its state, but each position reads (and updates) its own arguments.
A nested plan gets no wires here (see `_composite_dsl_add_inputs!`).
"""
_composite_dsl_call_wires(entity, producers::Dict{Symbol, Any}, inputs::Tuple) = ()
_composite_dsl_call_wires(entity::AbstractIdentifiableAlgo, producers::Dict{Symbol, Any}, inputs::Tuple) =
    _composite_dsl_call_wires(getalgo(entity), producers, inputs)
function _composite_dsl_call_wires(entity::Union{StepAlgorithm, Type{<:StepAlgorithm}}, producers::Dict{Symbol, Any}, inputs::Tuple)
    @nospecialize entity inputs
    wires = Any[]
    for input in inputs
        transform = hasproperty(input, :transform) ? input.transform : nothing
        source_owner = if input.kind in (:simple, :simple_transform)
            haskey(producers, input.source_field) || continue   # an outside input, recorded by `_composite_dsl_add_inputs!`
            producers[input.source_field]
        else
            input.owner
        end
        push!(wires, Route(source_owner => ThisChild(), input.source_field => input.target_field; transform))
    end
    return Tuple(wires)
end
function _composite_dsl_call_wires(entity::Callable, producers::Dict{Symbol, Any}, inputs::Tuple)
    @nospecialize entity inputs
    wires = Any[]
    for input in inputs
        transform = hasproperty(input, :transform) ? input.transform : nothing
        source_owner = if input.kind in (:simple, :simple_transform)
            haskey(producers, input.source_field) || continue   # an outside input, read by name
            producers[input.source_field]
        else
            input.owner
        end
        # Same name from the scope, untransformed: read by name, no wire.
        _dsl_read_by_name(source_owner) && input.source_field === input.target_field && isnothing(transform) && continue
        push!(wires, Route(source_owner => ThisChild(), input.source_field => input.target_field; transform))
    end
    return Tuple(wires)
end

"""Record the outside inputs (`@input`) a DSL call reads by name."""
function _composite_dsl_register_call_inputs!(external_inputs::Vector{Pair{Symbol, Symbol}}, producers::Dict{Symbol, Any}, inputs::Tuple)
    @nospecialize inputs
    for input in inputs
        input.kind == :simple && !haskey(producers, input.source_field) || continue
        mapping = input.source_field => input.source_field
        mapping in external_inputs || push!(external_inputs, mapping)
    end
    return external_inputs
end

"""
The inputs of a DSL statement: a call or a step algorithm records the outside names it reads (its wires are attached
to its position, see `_composite_dsl_call_wires`); a nested plan gets routes.
"""
_composite_dsl_add_inputs!(options::Vector{Any}, producers::Dict{Symbol, Any}, external_inputs::Vector{Pair{Symbol, Symbol}}, owner, entity::Union{StepAlgorithm, Type{<:StepAlgorithm}}, inputs::Tuple) =
    _composite_dsl_register_call_inputs!(external_inputs, producers, inputs)
_composite_dsl_add_inputs!(options::Vector{Any}, producers::Dict{Symbol, Any}, external_inputs::Vector{Pair{Symbol, Symbol}}, owner, entity::AbstractIdentifiableAlgo, inputs::Tuple) =
    _composite_dsl_add_inputs!(options, producers, external_inputs, owner, getalgo(entity), inputs)
_composite_dsl_add_inputs!(options::Vector{Any}, producers::Dict{Symbol, Any}, external_inputs::Vector{Pair{Symbol, Symbol}}, owner, entity, inputs::Tuple) =
    _composite_dsl_add_routes!(options, producers, external_inputs, owner, inputs)

"""A DSL call as a plan child: wrapped with its wires when it has any."""
_composite_dsl_with_wires(entity, wires::Tuple) = isempty(wires) ? entity : WithWiring(entity, wires)

"""Register outputs as the current producer for later routed lookups."""
function _composite_dsl_register_outputs!(producers::Dict{Symbol, Any}, owner, outputs::Tuple{Vararg{Symbol}})
    @nospecialize owner outputs
    # A call's outputs belong to its fixed namespace (`_captured_returns`), not to the call.
    owner = something(fixed_namespace(owner), owner)
    for output in outputs
        # A declared local stays one: the call writes it.
        _dsl_is_declared(get(producers, output, nothing)) && continue
        # Later statements resolve symbols by asking this table who currently
        # owns a given output name.
        producers[output] = owner
    end
    return producers
end

"""
The rules a DSL block is built with. `CurrentDSL` for `@CompositeAlgorithm` and `@Routine`; the legacy macros
(`src/Legacy`) pass their own, which differ only where their methods say so.
"""
abstract type DSLRules end
struct CurrentDSL <: DSLRules end

"""
Error for `x = @repeat spec stmt` (`lhs`, `spec`, `stmt` as written) under `CurrentDSL`: the return of a repeated
statement is not a value of the block. The legacy rules keep `x` as the last repeat's return.
"""
_dsl_check_repeat_capture(::DSLRules, lhs::String, spec::String, stmt::String) = nothing
_dsl_check_repeat_capture(::CurrentDSL, lhs::String, spec::String, stmt::String) =
    error("`$lhs = @repeat $spec $stmt` does not capture anything: the return of a repeated statement is not a value of the block. " *
          "Repeat the statement without `$lhs =`, or capture inside a repeated block: " *
          "`local $lhs; @repeat $spec begin $lhs = $stmt end` (without `local $lhs` when `$lhs` is already a name of the block).")

"""
Error for `x = nested()` with `nested` a plan, or `x = @repeat n begin … end` (`outputs` the names on the left), under
`CurrentDSL`: a plan has no return value. The legacy rules bind the names to the plan's fields of those names.
"""
_dsl_check_plan_capture(::DSLRules, outputs::Tuple{Vararg{Symbol}}) = nothing
function _dsl_check_plan_capture(::CurrentDSL, outputs::Tuple{Vararg{Symbol}})
    isempty(outputs) && return nothing
    names = join(("`$o`" for o in outputs), ", ")
    locals = join(("local $o" for o in outputs), "; ")
    error("Assigning $names to a nested plan: a plan has no return value: declare `$locals` before it and assign " *
          "$names inside the plan.")
end

"""Whether a DSL entity is a plan (`@CompositeAlgorithm` / `@Routine` block), which has no return value."""
_dsl_is_plan(entity) = false
_dsl_is_plan(entity::AbstractIdentifiableAlgo) = _dsl_is_plan(getalgo(entity))
_dsl_is_plan(::Union{AbstractPlan, AbstractLoopAlgorithm}) = true

"""The name the capture of an algorithm's return reads that return under (see `_composite_dsl_bind_returns!`)."""
const _DSL_RETURNED = :_returned

"""
Whether a DSL entity is an algorithm whose return value a statement captures (`y = Algo()`): a step algorithm, not a
call (a `Callable` captures its own return), a state or a nested plan.
"""
_dsl_captures_return(entity) = false
_dsl_captures_return(::Callable) = false
_dsl_captures_return(entity::AbstractIdentifiableAlgo) = _dsl_captures_return(getalgo(entity))
_dsl_captures_return(::Union{StepAlgorithm, Type{<:StepAlgorithm}}) = true
_dsl_captures_return(::ContextWrite) = false   # `x = v` writing a state field: the write is the statement

"""
Bind the names on the left of a statement (`outputs`, taken from the value as `returns` says, see `_dsl_returns_spec`).

A call (`Callable`) captures its own return. For an algorithm, the return value is captured by a call of `identity`
added right after it, on the same schedule, that reads the algorithm's return (`RETURN_NAME`) through a route: the
names become captured returns of the block, as for a call; a name that is a state field of the block is written there
(the call is wired to it), one that is a declared local writes the local. A nested plan has no return value: names on
the left of one are an error (`_dsl_check_plan_capture`).
"""
function _composite_dsl_bind_returns!(::CurrentDSL, algos::Vector{Any}, specification::Vector{Any}, options::Vector{Any}, producers::Dict{Symbol, Any}, state_owners::Dict{Symbol, Any}, entity, owner, returns, outputs::Tuple{Vararg{Symbol}}, schedule)
    @nospecialize entity owner returns outputs schedule
    _dsl_is_plan(entity) && _dsl_check_plan_capture(CurrentDSL(), outputs)
    (_dsl_captures_return(entity) && !isempty(outputs)) || return _composite_dsl_bind_outputs!(options, producers, state_owners, owner, outputs)
    to_state = Tuple(o for o in outputs if haskey(state_owners, o) && !_dsl_is_declared(get(producers, o, nothing)))
    wires = (Route(owner => ThisChild(), RETURN_NAME => _DSL_RETURNED), (Route(state_owners[o] => ThisChild(), o => o) for o in to_state)...)
    capture = Callable(identity, (_DSL_RETURNED,), returns)
    push!(algos, WithWiring(capture, wires))
    push!(specification, schedule)
    _composite_dsl_register_outputs!(producers, capture, Tuple(o for o in outputs if !(o in to_state)))
    foreach(o -> producers[o] = state_owners[o], to_state)
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
    if !isnothing(fixed_namespace(target))
        _composite_dsl_register_outputs!(producers, target, outputs)
        return producers
    end

    for output in outputs
        _dsl_is_declared(get(producers, output, nothing)) && continue   # a declared local stays one: the algorithm writes it
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
    if entity isa LoopSpec
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
_composite_dsl_entry(entity::WithWiring, name::Symbol) = WithWiring(_composite_dsl_entry(getfield(entity, :child), name), getfield(entity, :wires))
function _composite_dsl_entry(entity, name::Symbol)
    if name == Symbol() || entity isa LoopSpec
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

"""
Return the `Var` selector for a name in a lifetime condition (`x` in `@repeat Until(cond, x) …`): the block value
`x` as it is at this point, i.e. a `local`, a `@state` field or an earlier statement's captured result. Errors when
`x` is none of these.

It is never a field of the repeated algorithm's state: `x = f()` captures `f`'s return into the block value `x`, it
does not name `f`'s state, even when `f`'s state has a field `x`. The statement's owner and outputs are used only by
the legacy rules (`src/Legacy`).
"""
function _composite_dsl_var_selector(::DSLRules, producers::D, current_owner, current_outputs::Tuple, name::Symbol) where {D<:Dict{Symbol,Any}}
    haskey(producers, name) && return Var(_composite_dsl_var_owner(producers[name]), name)
    error("Lifetime selector `$name` is not a block value at this point: declare it before the statement (`local $name`, `@state $name = …`) or read an earlier result.")
end

"""Return the route target used for `owner.field = value` DSL writes.

Loop algorithms expose their inline state through the synthetic `._state`
property, so writes into a nested routine/composite must target that state owner.
Plain algorithms use the normal keyed owner wrapper.
"""
function _composite_dsl_write_owner(entity, name::Symbol)
    if entity isa LoopSpec
        return _composite_dsl_block_state(entity)
    end
    return IdentifiableAlgo(entity, name)
end

"""Return `true` for a block's own `@state`: a `GeneralState` carrying the id it got when the block was built."""
_composite_dsl_is_block_state(entry) = entry isa AbstractIdentifiableAlgo && getalgo(entry) isa GeneralState && id(entry) isa Union{SimpleId, NormalizedId}

"""Return the `@state` of the DSL block `entity` (its identified `GeneralState`), the owner of `c.field` references."""
function _composite_dsl_block_state(entity::LoopSpec)
    for state in getstates(entity)
        _composite_dsl_is_block_state(state) && return state
    end
    error("The block has no `@state`.")
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

"""Apply `func` to a tuple of state entries without rebuilding no-op tuples."""
Base.@nospecializeinfer function _composite_dsl_map_state_entries(func::F, @nospecialize(entries::Tuple)) where {F}
    mapped = Vector{Any}(undef, length(entries))
    changed = false
    for i in eachindex(mapped)
        mapped[i], entry_changed = _composite_dsl_map_state_entry(func, entries[i])
        changed |= entry_changed
    end
    return changed ? Tuple(mapped) : entries, changed
end

"""Apply a state transform through child algorithms without rebuilding no-op branches."""
Base.@nospecializeinfer function _composite_dsl_map_state_children(func::F, @nospecialize(children::Tuple)) where {F}
    mapped = Vector{Any}(undef, length(children))
    changed = false
    for i in eachindex(mapped)
        mapped[i], child_changed = _composite_dsl_map_states_changed(func, children[i])
        changed |= child_changed
    end
    return changed ? Tuple(mapped) : children, changed
end

"""Apply `func` to every process state contained by a loop-algorithm tree.

The DSL needs to update state metadata before the parent constructor flattens
nested algorithms into one registry. This tree walk preserves the executable
plan shape and only replaces branches that contain a changed state. Non-loop
algorithm leaves pass through unchanged.

The walk runs on untyped values (`@nospecialize`, `getfield`) so it is compiled once, not once per plan type: it
runs for every `@context` entry, and usually changes nothing. Only a branch that changed is rebuilt with the typed
constructors.
"""
Base.@nospecializeinfer function _composite_dsl_map_states_changed(func::F, @nospecialize(entity)) where {F}
    if entity isa LoopAlgorithm
        plan, plan_changed = _composite_dsl_map_states_changed(func, getfield(entity, :plan))
        plan_changed || return entity, false
        return setfield(entity, :plan, plan), true
    elseif entity isa Union{CompositeAlgorithm, Routine}
        funcs, funcs_changed = _composite_dsl_map_state_children(func, getfield(entity, :funcs))
        states, states_changed = _composite_dsl_map_state_entries(func, getfield(entity, :states))
        (funcs_changed || states_changed) || return entity, false
        return setstates(rebuild_loopalgorithm_funcs(entity, funcs), states), true
    elseif entity isa IdentifiableAlgo && getfield(entity, :func) isa LoopSpec
        inner, inner_changed = _composite_dsl_map_states_changed(func, getfield(entity, :func))
        inner_changed || return entity, false
        return setfield(entity, :func, inner), true
    end
    return entity, false
end

"""Return an entity with `func` applied to contained states."""
Base.@nospecializeinfer function _composite_dsl_map_states(func::F, @nospecialize(entity)) where {F}
    mapped, _ = _composite_dsl_map_states_changed(func, entity)
    return mapped
end

#=
Typed versions of the state walk above (`_composite_dsl_map_states` and its helpers), with the same results: tuple
recursion specialized on the plan type, so the type of the returned plan is known to the compiler.

Not used: the walk runs for every `@context` entry on values whose types are only known at run time, and the typed
version is compiled again for every plan type, which includes every new `Unique` handle, even when no state changes.
Kept for a typed construction path.
=#
@inline _composite_dsl_map_state_entries_typed(::F, entries::Tuple{}) where {F} = entries, false

function _composite_dsl_map_state_entries_typed(func::F, entries::Entries) where {F, Entries<:Tuple}
    head, head_changed = _composite_dsl_map_state_entry(func, first(entries))
    tail, tail_changed = _composite_dsl_map_state_entries_typed(func, Base.tail(entries))
    (head_changed || tail_changed) || return entries, false
    return (head, tail...), true
end

@inline _composite_dsl_map_state_children_typed(::F, children::Tuple{}) where {F} = children, false

function _composite_dsl_map_state_children_typed(func::F, children::Children) where {F, Children<:Tuple}
    head, head_changed = _composite_dsl_map_states_changed_typed(func, first(children))
    tail, tail_changed = _composite_dsl_map_state_children_typed(func, Base.tail(children))
    (head_changed || tail_changed) || return children, false
    return (head, tail...), true
end

function _composite_dsl_map_states_changed_typed(func::F, entity::LA) where {F, LA<:LoopAlgorithm}
    plan, plan_changed = _composite_dsl_map_states_changed_typed(func, getplan(entity))
    plan_changed || return entity, false
    return setfield(entity, :plan, plan), true
end

function _composite_dsl_map_states_changed_typed(func::F, entity::LA) where {F, LA<:Union{CompositeAlgorithm, Routine}}
    funcs, funcs_changed = _composite_dsl_map_state_children_typed(func, getalgos(entity))
    states, states_changed = _composite_dsl_map_state_entries_typed(func, getstates(entity))
    (funcs_changed || states_changed) || return entity, false
    return setstates(rebuild_loopalgorithm_funcs(entity, funcs), states), true
end

function _composite_dsl_map_states_changed_typed(func::F, entity::IA) where {F, Inner<:LoopSpec, IA<:AbstractIdentifiableAlgo{Inner}}
    inner, inner_changed = _composite_dsl_map_states_changed_typed(func, getalgo(entity))
    inner_changed || return entity, false
    return setfield(entity, :func, inner), true
end

_composite_dsl_map_states_changed_typed(::F, entity::E) where {F, E} = entity, false

"""Typed version of `_composite_dsl_map_states` (see the note above)."""
function _composite_dsl_map_states_typed(func::F, entity::E) where {F, E}
    mapped, _ = _composite_dsl_map_states_changed_typed(func, entity)
    return mapped
end

"""Prefix diagnostic state-field paths with a parent `@context` alias.

Warnings for overlapping anonymous `@state` fields are only useful when they
name where the fields came from. When a parent writes `@context f = child()`,
this changes diagnostic paths from `buffers` to `f.buffers` while leaving the
runtime field name as `:buffers`.
"""
Base.@nospecializeinfer function _composite_dsl_prefix_state_diagnostic_paths(@nospecialize(entity), context_alias::Symbol)
    return _composite_dsl_map_states(entity) do state
        state isa GeneralState || return state
        return prefix_general_state_diagnostic_paths(state, context_alias)
    end
end

"""The owner of the current block's state field `name` (for `@bind x => ...`), or an error if the block has none."""
function _composite_dsl_state_owner(state_owners::Dict{Symbol, Any}, name::Symbol)
    haskey(state_owners, name) || error("`@bind` uses `$name`, which is not a `@state` field of this block.")
    return state_owners[name]
end

"""Return the entry a `@context` alias was given (the nested block), from the constructor list of the current block."""
function _composite_dsl_context_entity(algos::Vector{Any}, context_indices::Dict{Symbol, Int}, context_alias::Symbol)
    haskey(context_indices, context_alias) || error("`@merge` references unknown context alias `$context_alias`. Declare it first with `@context $context_alias = ...`.")
    entry = algos[context_indices[context_alias]]
    return entry isa Pair ? entry.second : entry
end

"""
`@merge c1, c2, ...`: the `@state`s of these nested blocks become one state. It holds the fields of all of them (a field
they share is one field), and is matched by the id of each (`MatchAny`), so every reference to one of the merged states
finds it. It is pushed to the current block's states, which are registered before those of the nested blocks.
"""
function _composite_dsl_merge_states!(states::Vector{Any}, blocks::Tuple)
    merged = map(_composite_dsl_block_state, blocks)
    fields = Tuple(unique(Iterators.flatten(general_state_fields(getalgo(s)) for s in merged)))
    # Same-named fields are meant to be one here, so they are marked as shared and do not warn.
    state = reduce(merge, map(s -> mark_general_state_fields_explicitly_shared(getalgo(s), fields), merged))
    push!(states, IdentifiableAlgo(state, Symbol(), MatchAny{map(id, merged)}()))
    return states
end

"""
`@bind source => target ...`: inside what the bound statements built (`algos` after `algo_start`, `options` after
`option_start`), `target` is `source`. Each bind is `(source_owner, source_field, target_owner, target_field)`.

- Every route that reads `target` comes from `source` instead (`_composite_dsl_rebind`), also inside nested blocks;
  writes back go through the same routes.
- A nested block whose `@state` holds `target` no longer initializes that field.
- A target owned by an algorithm also gets a route from `source`, which wins over its own field.
"""
function _composite_dsl_rebind!(algos::Vector{Any}, options::Vector{Any}, algo_start::Int, option_start::Int, binds::Tuple)
    for i in algo_start+1:length(algos)
        algos[i] = _composite_dsl_rebind(algos[i], binds)
    end
    rewired = Any[]
    for option in options[option_start+1:end]
        append!(rewired, _composite_dsl_rebind_option(option, binds))
    end
    resize!(options, option_start)
    append!(options, rewired)
    for (source_owner, source_field, target_owner, target_field) in binds
        _composite_dsl_is_state_owner(target_owner) && continue
        push!(options, Route(source_owner => target_owner, source_field => target_field))
    end
    return algos, options
end

_composite_dsl_is_state_owner(owner) = owner isa AbstractIdentifiableAlgo && getalgo(owner) isa AlgoState

"""The bind (source owner, source field) that replaces reading `field` from an endpoint with matcher `endpoint_match`, or `nothing`."""
function _composite_dsl_bound_source(binds::Tuple, endpoint_match, field::Symbol)
    endpoint_match isa Symbol && return nothing
    for (source_owner, source_field, target_owner, target_field) in binds
        target_field == field && scref_match(target_owner) == endpoint_match && return (source_owner, source_field)
    end
    return nothing
end

"""A route with its bound variables split off and taken from their source; other options as they are."""
_composite_dsl_rebind_option(option, binds::Tuple) = (option,)
_composite_dsl_rebind_option(option::LocalPlanOption, binds::Tuple) =
    map(o -> LocalPlanOption(getfield(option, :owner), o), _composite_dsl_rebind_option(getfield(option, :option), binds))
function _composite_dsl_rebind_option(route::Route, binds::Tuple)
    isresolved(route) && return (route,)
    source_owner = isnothing(get_source_ref(route)) ? source_match_by(route) : get_source_ref(route)
    target_owner = isnothing(get_target_ref(route)) ? target_match_by(route) : get_target_ref(route)
    varnames, aliases = source_fieldnames(route), getaliases(route)
    kept = Pair{Symbol, Symbol}[]
    moved = Any[]
    for i in eachindex(varnames)
        bound = _composite_dsl_bound_source(binds, source_match_by(route), varnames[i])
        if isnothing(bound)
            push!(kept, varnames[i] => aliases[i])
        else
            push!(moved, Route(bound[1] => target_owner, bound[2] => aliases[i]; transform = gettransform(route), reverse_transform = getreverse_transform(route)))
        end
    end
    isempty(moved) && return (route,)
    isempty(kept) && return Tuple(moved)
    return (Route(source_owner => target_owner, kept...; transform = gettransform(route), reverse_transform = getreverse_transform(route)), moved...)
end

"""A nested block with `binds` applied to its wiring, its nested blocks and its `@state`; any other entry as it is."""
_composite_dsl_rebind(entry, binds::Tuple) = entry
_composite_dsl_rebind(entry::Pair, binds::Tuple) = entry.first => _composite_dsl_rebind(entry.second, binds)
_composite_dsl_rebind(la::LoopAlgorithm, binds::Tuple) = setfield(la, :plan, _composite_dsl_rebind(getplan(la), binds))
_composite_dsl_rebind(fa::FinalizedAlgorithm, binds::Tuple) = finalstep(_composite_dsl_rebind(inneralgorithm(fa), binds), finalfunction(fa))
# A statement's own wires (`WithWiring`, see `_composite_dsl_call_wires`) are rebound where they are.
_composite_dsl_rebind(w::WithWiring, binds::Tuple) =
    WithWiring(_composite_dsl_rebind(getfield(w, :child), binds), _composite_dsl_rebind_wires(getfield(w, :wires), binds))
_composite_dsl_rebind(w::IfWrapped, binds::Tuple) = IfWrapped(_composite_dsl_rebind(getfield(w, :algo), binds), getfield(w, :cond))
_composite_dsl_rebind_wires(wires::Tuple, binds::Tuple) = Tuple(Iterators.flatten(_composite_dsl_rebind_option(w, binds) for w in wires))

function _composite_dsl_rebind(plan::AbstractPlan, binds::Tuple)
    wiring = getwiring(plan)
    funcs = map(f -> _composite_dsl_rebind(f, binds), getalgos(plan))
    plan_wide = global_wiring(wiring)
    options = Any[]
    for option in (routes(plan_wide)..., shares(plan_wide)...)
        append!(options, _composite_dsl_rebind_option(option, binds))
    end
    # The routes of one child stay with its position (re-attached with `WithWiring`, not by matching the child, which
    # would give two equal children each other's routes); its shares are matched to it.
    buckets = child_wiring(wiring)
    children = Any[]
    for i in eachindex(funcs)
        bucket = buckets[i]
        if bucket isa Wiring && !isempty(bucket)
            foreach(share -> push!(options, LocalPlanOption(funcs[i], share)), shares(bucket))
            push!(children, isempty(routes(bucket)) ? funcs[i] : WithWiring(funcs[i], _composite_dsl_rebind_wires(routes(bucket), binds)))
        else
            push!(children, funcs[i])
        end
    end
    raw, child_buckets = _split_children_and_wiring(Tuple(children), Tuple(options))
    rewired = PlanWiring(_build_plan_wiring(Tuple(options)), child_buckets, getfield(wiring, :locals))
    plan = setfield(rebuild_loopalgorithm_funcs(plan, raw), :wiring, rewired)
    # A block state left without fields is dropped.
    states = filter(s -> !_composite_dsl_is_empty_state(s), map(s -> _composite_dsl_unbind_state(s, binds), getstates(plan)))
    return setstates(plan, states)
end

_composite_dsl_is_empty_state(state) = _composite_dsl_is_block_state(state) && isempty(general_state_fields(getalgo(state)))

"""A block's `@state` without the fields bound to a source elsewhere."""
function _composite_dsl_unbind_state(state, binds::Tuple)
    _composite_dsl_is_block_state(state) || return state
    match = scref_match(state)
    fields = Tuple(target_field for (_, _, target, target_field) in binds if scref_match(target) == match)
    isempty(fields) && return state
    return setfield(state, :func, _general_state_without(getalgo(state), fields))
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
    # A block's own state gets an id here, once per construction, so two blocks built from the same code keep separate
    # state (`_state_1`, `_state_2`); a named state is keyed by its name and shared by every state with that name.
    state_entry_expr = state_name == :_state ?
        :(StatefulAlgorithms.IdentifiableAlgo($state_expr, Symbol(), StatefulAlgorithms.uuid4())) :
        :($(QuoteNode(state_name)) => $state_expr)
    state_owner_expr = state_name == :_state ? :(_dsl_state) : _dsl_known_owner_expr(:(_dsl_state.second), state_name)
    return quote
        local _dsl_state = $state_entry_expr
        push!(_dsl_states, _dsl_state)
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
        push!(_dsl_states, :_inputs => _dsl_input_state)
        push!(_dsl_options, StatefulAlgorithms.RuntimeInputs(_dsl_runtime_input_specs))
        local _dsl_input_owner = StatefulAlgorithms._composite_dsl_owner(_dsl_input_state, :_inputs)
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
    elseif _dsl_is_property_destructuring(lhs)
        return Tuple(only(lhs.args).args)
    elseif lhs isa Expr && lhs.head == :tuple
        all(x -> x isa Symbol, lhs.args) || error("Multi-output bindings must use plain symbols like `a, b = algo`.")
        return tuple(lhs.args...)
    end
    return nothing
end

"""Whether `lhs` is `(; a, b)`: the properties `a` and `b` of the value on the right."""
_dsl_is_property_destructuring(lhs) = lhs isa Expr && lhs.head == :tuple && length(lhs.args) == 1 &&
    only(lhs.args) isa Expr && only(lhs.args).head == :parameters && all(a -> a isa Symbol, only(lhs.args).args)

"""
How a statement's left-hand side takes the value on the right, as `Callable` returns: `y` the whole value, `a, b`
unpacked, `(; a, b)` its properties `a` and `b`; `()` for no left-hand side.
"""
function _dsl_returns_spec(lhs)
    lhs isa Symbol && return QuoteNode(lhs)
    # A value, not an expression: the names must not be renamed by the macro's hygiene.
    _dsl_is_property_destructuring(lhs) && return NamedTuple{Tuple(only(lhs.args).args)}(Tuple(only(lhs.args).args))
    outputs = _dsl_parse_output_symbols(lhs)
    return Expr(:tuple, QuoteNode.(outputs)...)
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

