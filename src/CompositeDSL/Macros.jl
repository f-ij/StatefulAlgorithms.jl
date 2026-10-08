"""Create a `GeneralState` value directly."""
macro state(args...)
    fields = _dsl_collect_state_fields(args)
    return _dsl_expand_state_expr(fields)
end

"""Return the concrete loop-algorithm constructor represented by a DSL macro."""
@inline _dsl_loopalgorithm_type(::Val{:CompositeAlgorithm}) = CompositeAlgorithm
@inline _dsl_loopalgorithm_type(::Val{:Routine}) = Routine
@inline _dsl_loopalgorithm_type(::Val{Name}) where {Name} =
    error("Unsupported DSL loop algorithm constructor `$Name`.")

"""Normalize DSL-collected process state entries without a large vararg parse."""
function _dsl_normalize_state_entries(states)
    normalized = Any[]
    sizehint!(normalized, length(states))
    for state in states
        if state isa Pair
            push!(normalized, IdentifiableAlgo(state.second, state.first))
        elseif state isa Union{ProcessState, Type{<:ProcessState}}
            push!(normalized, IdentifiableAlgo(state))
        else
            push!(normalized, state)
        end
    end
    return Tuple(normalized)
end

"""Build a loop algorithm from DSL vectors without compiling a giant vararg call."""
function _dsl_build_loopalgorithm(::Val{Name}, algos, specification, states, options) where {Name}
    laType = _dsl_loopalgorithm_type(Val(Name))
    length(algos) == length(specification) || error("DSL produced $(length(algos)) algorithms but $(length(specification)) schedule entries.")

    processalgos = Any[]
    kept_specification = Any[]
    sizehint!(processalgos, length(algos))
    sizehint!(kept_specification, length(specification))

    # Conditional DSL branches use `IfWrapped`; keep specification entries
    # aligned only for algorithms that survive constructor-time filtering.
    for idx in eachindex(algos)
        parsed = _parse_loopalgorithm_entity_input(algos[idx])
        isnothing(parsed) && continue
        parsed = _strip_nested_finalized_algorithm(parsed)
        push!(processalgos, _normalize_loopalgorithm_entity_input(parsed))
        push!(kept_specification, specification[idx])
    end
    isempty(processalgos) && error("`@$Name` requires at least one algorithm entry.")

    processalgos_tuple = Tuple(processalgos)
    schedule_tuple = Tuple(kept_specification)
    normalized_schedule = if iscomposite(laType)
        map(x -> x isa Interval ? x : Interval(x), schedule_tuple)
    else
        map(x -> x isa Lifetime ? x : Repeat(x), schedule_tuple)
    end

    if iscomposite(laType)
        processalgos_tuple, normalized_schedule = flatten_comp_funcs(processalgos_tuple, normalized_schedule)
    end

    collected_options = ()
    for algo in processalgos_tuple
        if algo isa LoopAlgorithm && isresolved(algo)
            collected_options = (unique(collected_options)..., update_option_keys(algo)...)
        end
    end

    state_tuple = _dsl_normalize_state_entries(states)
    option_tuple = (collected_options..., Tuple(options)...)
    return LoopAlgorithm(laType, processalgos_tuple, state_tuple, option_tuple, normalized_schedule)
end

"""Expand a top-level DSL block into either a `CompositeAlgorithm` or a `Routine`."""
function _dsl_expand_loopalgorithm(block, constructor_name::Symbol, expected_schedule::Symbol; print_constructor::Bool = false)
    statements = block isa Expr && block.head == :block ? block.args : Any[block]
    collected = _dsl_collect_block(statements, expected_schedule, constructor_name; allow_final = true)

    state_setup_expr = _dsl_state_setup_expr(collected.state_fields, collected.state_name)
    input_setup_expr = _dsl_runtime_input_setup_expr(collected.input_fields)
    final_expr = collected.final_expr

    expanded = quote
        let
            # Keep the emitted block literal and local so the resulting macro
            # expansion is easy to inspect in lowered code.
            local _dsl_algos = Any[]
            local _dsl_states = Any[]
            local _dsl_options = Any[]
            local _dsl_specification = Any[]
            local _dsl_producers = Dict{Symbol, Any}()
            local _dsl_state_owners = Dict{Symbol, Any}()
            local _dsl_external_inputs = Pair{Symbol, Symbol}[]
            local _dsl_context_indices = Dict{Symbol, Int}()

            $(isnothing(state_setup_expr) ? nothing : state_setup_expr)
            $(isnothing(input_setup_expr) ? nothing : input_setup_expr)
            $(collected.step_exprs...)

            isempty(_dsl_algos) && error("`@$constructor_name` requires at least one algorithm entry.")
            $(print_constructor ? :(StatefulAlgorithms._dsl_print_constructor_call($(QuoteNode(constructor_name)), _dsl_algos, _dsl_specification, _dsl_states, _dsl_options)) : nothing)
            # Build the final `CompositeAlgorithm`/`Routine` using the same
            # constructor surface users would write by hand.
            local _dsl_loopalgorithm = StatefulAlgorithms._dsl_build_loopalgorithm(
                Val{$(QuoteNode(constructor_name))}(),
                _dsl_algos,
                _dsl_specification,
                _dsl_states,
                _dsl_options,
            )
            $(isnothing(final_expr) ? :(_dsl_loopalgorithm) : :(StatefulAlgorithms.finalstep(_dsl_loopalgorithm, $(esc(final_expr)))))
        end
    end
    return _dsl_strip_generated_linenums!(expanded)
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

"""
Expand the body used inside `@repeat n begin ... end` into a `CompositeAlgorithm`.

Nested repeat blocks inherit surrounding aliases for route parsing, while any
alias declarations inside the nested block remain local to that nested block.
"""
function _dsl_expand_simplealgorithm_resolved(
    block,
    initial_alias_map::Dict{Symbol, Any} = Dict{Symbol, Any}(),
    initial_context_map::Dict{Symbol, Any} = Dict{Symbol, Any}(),
)
    statements = block isa Expr && block.head == :block ? block.args : Any[block]
    collected = _dsl_collect_block(
        statements,
        :none,
        :repeat;
        allow_final = false,
        initial_alias_map,
        initial_context_map,
    )

    state_setup_expr = _dsl_state_setup_expr(collected.state_fields, collected.state_name)
    input_setup_expr = _dsl_runtime_input_setup_expr(collected.input_fields)

    expanded = quote
        let
            # The inner repeated block is built exactly once as a plain
            # `CompositeAlgorithm`, then wrapped by the outer `Routine`.
            local _dsl_algos = Any[]
            local _dsl_states = Any[]
            local _dsl_options = Any[]
            local _dsl_specification = Any[]
            local _dsl_producers = Dict{Symbol, Any}()
            local _dsl_state_owners = Dict{Symbol, Any}()
            local _dsl_external_inputs = Pair{Symbol, Symbol}[]
            local _dsl_context_indices = Dict{Symbol, Int}()

            $(isnothing(state_setup_expr) ? nothing : state_setup_expr)
            $(isnothing(input_setup_expr) ? nothing : input_setup_expr)
            $(collected.step_exprs...)

            isempty(_dsl_algos) && error("`@repeat n begin ... end` requires at least one algorithm entry.")
            local _dsl_algo = StatefulAlgorithms._dsl_build_loopalgorithm(
                Val{:CompositeAlgorithm}(),
                _dsl_algos,
                _dsl_specification,
                _dsl_states,
                _dsl_options,
            )
            # Return the same resolved wrapper the outer builder expects from any
            # other DSL statement.
            local _dsl_inputs = Tuple((; kind = :simple, source = input.first, destination = input.second) for input in _dsl_external_inputs)
            StatefulAlgorithms._CompositeDSLResolved{:algo, typeof(_dsl_algo), typeof(_dsl_inputs)}(_dsl_algo, _dsl_inputs)
        end
    end
    return _dsl_strip_generated_linenums!(expanded)
end

"""Wrap a repeated DSL block in a `Routine`, then expose it as one routable entity."""
function _dsl_expand_repeated_block(
    block,
    repeats_expr,
    initial_alias_map::Dict{Symbol, Any} = Dict{Symbol, Any}(),
    initial_context_map::Dict{Symbol, Any} = Dict{Symbol, Any}(),
)
    inner_expr = _dsl_expand_simplealgorithm_resolved(block, initial_alias_map, initial_context_map)
    expanded = quote
        let
            local _dsl_inner = $inner_expr
            local _dsl_owner = nothing
            local _dsl_outputs = ()
            local _dsl_repeats = $(_dsl_repeat_schedule_expr(repeats_expr))
            local _dsl_algo = StatefulAlgorithms.Routine(_dsl_inner.entity, (_dsl_repeats,))
            local _dsl_inputs = _dsl_inner.inputs
            StatefulAlgorithms._CompositeDSLResolved{:algo, typeof(_dsl_algo), typeof(_dsl_inputs)}(_dsl_algo, _dsl_inputs)
        end
    end
    return _dsl_strip_generated_linenums!(expanded)
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
- `state_field = captured_value`

ProcessAlgorithm routes:
- `x = Algo(input = produced)`
- `x = Algo(left = a, right = b)`
- `x = Algo(value = @transform(x -> x * 2, produced))`
- `x = Algo(value = @transform(x -> x + bias, produced))`
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

State composition:
- `@bind buffers => c.buffers`
- `@merge c1.buffers, c2.buffers`

When nested DSL blocks declare overlapping inline state fields, the merge is
allowed for compatibility but warns unless the parent block documents the sharing
with `@bind` or `@merge`. `@bind` marks sharing from the current block's state
field into a child state field. `@merge` marks peer child state fields as the
same shared slot. Explicit `_state` selectors like `c._state.buffers`
are accepted anywhere `c.buffers` is accepted.

Direct owned-field access like `dynamics.state` is also accepted in route
positions. It routes directly from the known `:dynamics` owner with source
`:state`, even if no earlier statement bound `state = dynamics()`. The special
binding form `state = dynamics.state` exposes that same owned field under the
plain DSL output name `state` for later statements.

Full-context shares:
- `Algo(@all(source))`
- `Algo(@all(alias...))`

`@all(...)` lowers to a statement-local `Share(raw_source, raw_target)` option.
The DSL does not manufacture unnecessary `IdentifiableAlgo` wrappers for the
source endpoint; keyed matching is left to normal runtime registration logic.

Top-level plan routes can be written as route statements:
- `@route source.produced => sink.value`
- `@route source.value => sink.input transform = x -> 2x reverse_transform = y -> y / 2`

Known `@alias` names and `@context` references are accepted in those endpoint
positions. Normal call inputs still create statement-local wiring.

Scheduling:
- `x = @interval n Algo(...)`
- `x = @every n Algo(...)`
- `x = @interval n f(produced)`
- `x = @repeat n begin ... end`

Constructor-time conditional inclusion:
- `@include_if condition Algo(...)`
- `@include_if condition begin ... end`

The condition is evaluated when constructing the loop algorithm. Skipped entries
are not registered and do not contribute routes, shares, or schedules.

Current transform-route rules
=============================

Transformed routes must be written explicitly with `@transform(f, source)`. For
example:

`consumer(value = @transform(x -> x^2, a))`

The `source` part is resolved exactly like a normal route source, so it can be a
previous DSL output symbol such as `a` or an owned-field reference such as
`dynamics.state` or `c1.plus_capture.captured`.

Use a top-level `@route ... reverse_transform = g` statement when transformed
route writeback should update the backing source field.

State rebinding
===============

If an output name already belongs to the inline DSL state, assigning to that name
does not replace the state owner. Instead, the produced value is routed back into
that state slot.

Plain captured state writes
===========================

Assignments like `state_field = captured_value` lower to `ContextWrite`, which
captures the right-hand-side Julia value and writes it back through the existing
state writeback route. Use function or algorithm call syntax when the right-hand
side should be routed or stepped instead of captured.

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
- `@include_if enabled x = Algo(input = value)`
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
