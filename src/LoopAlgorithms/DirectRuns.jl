# Direct runs: a plan run from the user's own code, with no process around it (mode 1, "Modes of operation" in
# TODO.md). The user pipeline is `setup` (plan spec and `InitArgs(...)` -> context and resolved plan), `run(plan,
# context)`, `init(plan, context, Only(...), InitArgs(...))` (init again, all or `Only` some) and `cleanup(plan, context)`
# (docs/src/user/pipeline.md).
# A plan holds no data: the user keeps the context. Processes build their context with `setup` too. The
# `prepare_for_loop` method for a plan is in the hook-extensions section at the end.

export setup

# Merge `InitArgs`/`Override` specs by target, later ones winning: several specs for one target in one `setup` call, or a
# process's stored specs and new ones (`copyprocess`).
@inline _merge_specs_by_target(base::B, ::Tuple{}) where {B<:Tuple} = base
@inline _merge_specs_by_target(::Tuple{}, updates::Tuple{}) = ()
@inline _merge_specs_by_target(::Tuple{}, updates::Tuple{T}) where {T} = updates

@inline _resolve_lifecycle_specs(reg::R) where {R<:NameSpaceRegistry} = ()

"""
Merge two tuples of resolved lifecycle specs by target key.

When a target appears in both tuples, its named values are merged and the newer
values win. The result remains a tuple so callers can specialize on the concrete
set of lifecycle specs.
"""
function _merge_specs_by_target(base::B, updates::U) where {B<:Tuple, U<:Tuple}
    merged = collect(Any, base)
    for update in updates
        target = get_target_name(update)
        idx = findfirst(spec -> get_target_name(spec) == target, merged)
        if isnothing(idx)
            push!(merged, update)
        else
            old = merged[idx]
            vars = merge(get_vars(old), get_vars(update))
            merged[idx] = update isa InitArgs ? InitArgs{target,typeof(vars),typeof(get_ref(update))}(vars, get_ref(update)) : Override{target,typeof(vars),typeof(get_ref(update))}(vars, get_ref(update))
        end
    end
    return Tuple(merged)
end

"""
Split resolved lifecycle specs into initialization and override phases.

`InitArgs` values must be available during `init(...)`; `Override` values are
applied afterwards to force persistent context fields.
"""
function _split_init_override(specs)
    inits = filter_by_type(InitArgs, specs)
    overrides = filter_by_type(Override, specs)
    return inits, overrides
end

"""
Resolve `InitArgs`, `Override`, `Interactive` and `Only` targets through a concrete registry.

The returned specs carry symbol targets, so later context merging does not need
to perform matcher lookup again.
"""
@inline function _resolve_lifecycle_specs(reg::R, specs) where {R<:NameSpaceRegistry}
    resolved = ()
    for spec in specs
        if spec isa InputInterface
            resolved = (resolved..., resolve(reg, spec)...)
        else
            error("Expected InitArgs, Override, Interactive or Only, got $(spec).")
        end
    end
    return resolved
end

"""
Build the starting context of the resolved plan `la` from resolved `InitArgs`/`Override`/`Interactive` specs.

`init` runs on an `InitContext`, which also carries `algo` and `lifetime`. In order: the empty context, the `InitArgs` values
merged in, every registered algorithm's `init`, the `Override` values, the `Interactive` specs, the redirects.
"""
@inline function _init_context_for(la::LA, inits::I, overrides::O, interactives::IA, lifetime::LT) where {LA<:AbstractLoopAlgorithm, I<:Tuple, O<:Tuple, IA<:Tuple, LT}
    empty_context = ProcessContext(getregistry(la))
    input_context = isempty(inits) ? empty_context : merge_into_subcontexts(empty_context, construct_context_merge_tuples(inits))
    prepared = init(la, InitContext(input_context, la, lifetime))
    prepared_context = @inline _init_state_context(prepared, input_context)
    overridden_context = isempty(overrides) ? prepared_context : merge_into_subcontexts(prepared_context, construct_context_merge_tuples(overrides))
    interactive_context = @inline apply_interactive_specs(overridden_context, interactives)
    return @inline apply_redirect_specs(interactive_context, la)
end

"""
    _merged_lifecycle_specs(reg, specs) -> (inits, overrides, interactives)

Resolves `specs` against `reg` (resolved ones, such as a process's stored specs, stay as they are) and merges them per
target, later ones winning: `InitArgs` with `InitArgs`, `Override` with `Override`, `Interactive` names combined. An
`Only` is not a spec to keep and is an error here; `_split_only` takes it out first.
"""
function _merged_lifecycle_specs(reg::R, specs::S) where {R<:NameSpaceRegistry, S<:Tuple}
    resolved = _resolve_lifecycle_specs(reg, specs)
    any(spec -> spec isa Only, resolved) && throw(ArgumentError("Only selects which `init` functions run; it is passed to `init(plan, context, ...)` or `init!(p, ...)`, not here."))
    inits, overrides, interactives = _split_lifecycle_specs(resolved)
    return (_merge_specs_by_target((), inits),
            _merge_specs_by_target((), overrides),
            _merge_interactives_by_target((), interactives))
end

"""
    _split_only(reg, specs) -> (only, rest)

Takes the `Only(...)` out of the specs given to `init`/`init!`: `only` is it, resolved against `reg`, or `nothing` when
there is none (every `init` runs). More than one `Only` is an error. With an `Only`, an `InitArgs(ToAll(); ...)` in
`rest` goes to the `Only` targets alone.
"""
function _split_only(reg::R, specs::S) where {R<:NameSpaceRegistry, S<:Tuple}
    onlys = filter(spec -> spec isa Only, specs)
    length(onlys) > 1 && throw(ArgumentError("At most one Only per call, got $(length(onlys)): $(onlys)."))
    rest = filter(spec -> !(spec isa Only), specs)
    isempty(onlys) && return nothing, rest
    only = first(resolve(reg, first(onlys)))
    rest = map(spec -> _is_to_all_ns(spec) ? InitArgs{only_targets(only)}(get_vars(spec)) : spec, rest)
    return only, rest
end

"""
    setup(plan_spec, InitArgs(...), Override(...); lifetime = Indefinite()) -> (context, plan)

The first step of the user pipeline (setup, `run`, `cleanup`) for a plan run without a process: resolves `plan_spec`
and builds its starting context. Every algorithm's `init` runs; `InitArgs(...)` gives the values it reads,
`Override(...)` values are set after it. `lifetime` is what init may size buffers by. Returns the context and the
resolved plan; the plan holds no context, the user keeps the context and passes it to `run(plan, context)`. The
context has the `Unique` handles the user holds as keys found from types (`with_held_ids`): `context[handle]`.
"""
function setup(plan_spec::LA, specs::InputInterface...; lifetime = Indefinite()) where {LA<:LoopSpec}
    context, plan = _setup(plan_spec, specs...; lifetime)
    return with_held_ids(context), plan
end

"""`setup` as SA works with it: the context without the plan's `UniqueKeyMap`. A process sets up a new context with it
from its resolved plan and stored specs (`reset(ip)`, the error path of `close`)."""
function _setup(plan_spec::LA, specs::InputInterface...; lifetime = Indefinite()) where {LA<:LoopSpec}
    plan = resolve(plan_spec)
    inits, overrides, interactives = _merged_lifecycle_specs(getregistry(plan), specs)
    return _init_context_for(plan, inits, overrides, interactives, lifetime), plan
end

"""
    run(plan, context; repeats = 1, lifetime = nothing, inputs...) -> (context, result)

Runs the resolved `plan` (from `setup`) on `context` with no process around it and returns the run's final context and
its result (what the plan's finalizer returns). The run lasts `lifetime`, or `repeats` repeats when no lifetime is
given. The keyword `inputs` are the run's `@input` values, checked against the plan's declarations. The runtime
context (inputs, declared locals, returns) is dropped when the run ends; only the state context comes back. A context
from `setup` is run without its `UniqueKeyMap` (`strip_held_ids`); the one that comes back has it again.
"""
function Base.run(plan::LA, context::C; repeats = 1, lifetime = nothing, kwargs...) where {LA<:LoopSpec, C<:ProcessContext}
    isresolved(plan) || throw(ArgumentError("run(plan, context) needs the resolved plan that `setup` returns."))
    lt = parse_lifetime(lifetime, isnothing(lifetime) ? repeats : nothing)
    session, plan, lc = prepare_for_loop(plan, strip_held_ids(context), (; kwargs...), Resuming{false}())
    final_context, result = run_session_loop(session, plan, lc, lt)
    return with_held_ids(final_context), result
end

"""
    init(plan, context, InitArgs(...), Override(...); lifetime = Indefinite()) -> context
    init(plan, context, Only(A, B), InitArgs(...), Override(...); lifetime = Indefinite()) -> context

Runs `init` again on `context` and returns the new context; `plan` is the resolved plan from `setup`. Without `Only`
every algorithm's `init` runs; with `Only(A, B)` only A's and B's run (in registry order) and the rest of the context
is kept. Each `init` reads its part of `context` with the `InitArgs` values merged in; `Override` values are set after
it (an `Override` for a target whose `init` does not run only sets its values). `InitArgs` for a target outside the
`Only` is an error. `lifetime` is what a full init may size buffers by. To start from an empty context instead, use
`setup`. A context from `setup` comes back with the `Unique` handles the user holds as keys (`with_held_ids`).
"""
function init(plan::LA, context::C, specs::InputInterface...; lifetime = Indefinite()) where {LA<:LoopSpec, C<:ProcessContext}
    return with_held_ids(_init_again(plan, strip_held_ids(context), specs...; lifetime))
end

"""`init(plan, context, ...)` on a context without the plan's `UniqueKeyMap`."""
function _init_again(plan::LA, context::C, specs::InputInterface...; lifetime = Indefinite()) where {LA<:LoopSpec, C<:ProcessContext}
    isresolved(plan) || throw(ArgumentError("init(plan, context, ...) needs the resolved plan that `setup` returns."))
    reg = getregistry(plan)
    only, rest = _split_only(reg, specs)
    inits, overrides, interactives = _merged_lifecycle_specs(reg, rest)
    isnothing(only) && return _init_on_context(plan, context, inits, overrides, interactives, lifetime)
    targets = only_targets(only)
    for spec in inits
        get_target_name(spec) in targets || throw(ArgumentError("InitArgs for $(get_target_name(spec)), which Only$(targets) does not name: its `init` does not run."))
    end
    for named_algo in all_algos(reg)
        key = getkey(named_algo)
        key in targets || continue
        init_vars = map(get_vars, filter(i -> get_target_name(i) == key, inits))
        override_vars = map(get_vars, filter(o -> get_target_name(o) == key, overrides))
        context = init_namespace(context, named_algo; inputs = isempty(init_vars) ? (;) : first(init_vars),
                                  overrides = isempty(override_vars) ? (;) : first(override_vars))
    end
    lone_overrides = filter(o -> !(get_target_name(o) in targets), overrides)
    context = isempty(lone_overrides) ? context : merge_into_subcontexts(context, construct_context_merge_tuples(lone_overrides))
    context = @inline apply_interactive_specs(context, interactives)
    return @inline apply_redirect_specs(context, plan)
end

"""
Every algorithm's `init` on `context` (the full `init(plan, context, ...)`): the `InitArgs` values merged in, every
`init`, the `Override` values, the `Interactive` specs, the redirects. `_init_context_for` is the same from an empty
context.
"""
function _init_on_context(plan::LA, context::C, inits::I, overrides::O, interactives::IA, lifetime::LT) where {LA<:LoopSpec, C<:ProcessContext, I<:Tuple, O<:Tuple, IA<:Tuple, LT}
    input_context = isempty(inits) ? context : merge_into_subcontexts(context, construct_context_merge_tuples(inits))
    prepared = init(plan, InitContext(input_context, plan, lifetime))
    prepared_context = @inline _init_state_context(prepared, input_context)
    overridden_context = isempty(overrides) ? prepared_context : merge_into_subcontexts(prepared_context, construct_context_merge_tuples(overrides))
    interactive_context = @inline apply_interactive_specs(overridden_context, interactives)
    return @inline apply_redirect_specs(interactive_context, plan)
end

##########################################
########## Hook extensions ###############
##########################################

"""
    prepare_for_loop(plan, context, inputs, resume)

A plan run directly (`run(plan, context)`): a new `InlineSession` for the run (the loop needs a counter; nothing can pause or
close a direct run), the plan, and the `LoopContext` from `context` and the run's inputs (Processes/Hooks.jl).
"""
@inline prepare_for_loop(plan::LA, context::C, inputs::I, resume::Resuming{false}) where {LA<:LoopSpec, C<:ProcessContext, I<:NamedTuple} =
    InlineSession(), plan, (@inline with_inputs((@inline LoopContext(plan, context)), plan, inputs))
