# Direct runs: a plan run from the user's own code, with no process around it (mode 1, "Modes of operation" in
# TODO.md). The user pipeline is `setup` (plan spec and `Init(...)` specs -> context and resolved plan), `run(plan,
# context)` and `cleanup(plan, context)` (docs/src/user/pipeline.md). The older calls `init(la, Init(...), Override(...))`
# (builds the plan's state context), `partialinit` (re-initializes only the named targets) and `run(la; inputs...)`
# store the context and the Init/Override specs in the returned `LoopAlgorithm`; the Init/Override merging below exists
# to replay those stored specs. The `prepare_for_loop` method for a plan is in the hook-extensions section at the end.

export setup, partialinit

# Merge newly passed `Init`/`Override` specs over previously stored specs by
# target. This lets `init(initialized, Init(Target; ...))` replay the old
# lifecycle while replacing only the named target.
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
            merged[idx] = update isa Input ? Input{target,typeof(vars),typeof(get_ref(update))}(vars, get_ref(update)) : Override{target,typeof(vars),typeof(get_ref(update))}(vars, get_ref(update))
        end
    end
    return Tuple(merged)
end

"""
Split resolved lifecycle specs into initialization and override phases.

`Init` values must be available during `init(...)`; `Override` values are
applied afterwards to force persistent context fields.
"""
function _split_init_override(specs)
    inits = filter_by_type(Input, specs)
    overrides = filter_by_type(Override, specs)
    return inits, overrides
end

"""
Resolve `Init` and `Override` targets through a concrete registry.

The returned specs carry symbol targets, so later context merging does not need
to perform matcher lookup again.
"""
@inline function _resolve_lifecycle_specs(reg::R, specs) where {R<:NameSpaceRegistry}
    resolved = ()
    for spec in specs
        if spec isa InputInterface
            resolved = (resolved..., resolve(reg, spec)...)
        else
            error("Expected Init, Override, or Interactive, got $(spec).")
        end
    end
    return resolved
end

@inline _resolve_lifecycle_specs(la::LA, specs) where {LA<:AbstractLoopAlgorithm} =
    _resolve_lifecycle_specs(getregistry(resolve(la)), specs)

"""
Build the persistent context for an initialized loop algorithm.

Init runs on an `InitContext`, which also carries `algo` and `lifetime`. In order: the empty context, the `Init` values
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
    setup(plan_spec, Init(...), Override(...); lifetime = Indefinite()) -> (context, plan)

The first step of the user pipeline (setup, `run`, `cleanup`) for a plan run without a process: resolves `plan_spec`
and builds its starting context. The `Init(...)` specs say which values go to which algorithm before its `init` runs,
`Override(...)` values are set after it. `lifetime` is what init may size buffers by. Returns the context and the
resolved plan; the plan holds no context, the user keeps the context and passes it to `run(plan, context)`.
"""
function setup(plan_spec::LA, specs::InputInterface...; lifetime = Indefinite()) where {LA<:LoopSpec}
    plan = _without_lifecycle(resolve(plan_spec))
    inits, overrides, interactives = _split_lifecycle_specs(_resolve_lifecycle_specs(getregistry(plan), specs))
    return _init_context_for(plan, inits, overrides, interactives, lifetime), plan
end

"""
    init(la::LoopAlgorithm, Init(...), Override(...))

Fully initialize `la`, replaying stored init/override specs and letting passed
specs override stored specs per target.
"""
@inline function init(la::LA, specs::InputInterface...; lifetime = Indefinite()) where {LA<:LoopSpec}
    resolved = _without_lifecycle(resolve(la))
    new_specs = _resolve_lifecycle_specs(getregistry(resolved), specs)
    new_inits, new_overrides, new_interactives = _split_lifecycle_specs(new_specs)
    stored_overrides, stored_interactives = _split_override_interactive(getstoredoverrides(la))
    inits = _merge_specs_by_target(getstoredinits(la), new_inits)
    overrides = _merge_specs_by_target(stored_overrides, new_overrides)
    interactives = _merge_interactives_by_target(stored_interactives, new_interactives)
    context = _init_context_for(resolved, inits, overrides, interactives, lifetime)
    return _with_lifecycle(resolved, context, inits, (overrides..., interactives...))
end

"""
    partialinit(la, Init(...), Override(...))

Re-initialize only the targets named by the passed specs.
"""
function partialinit(la::LA, specs::InputInterface...) where {LA<:AbstractLoopAlgorithm}
    context = getpersistentcontext(la)
    isnothing(context) && error("partialinit requires an initialized LoopAlgorithm.")
    resolved_specs = _resolve_lifecycle_specs(la, specs)
    inits, overrides, interactives = _split_lifecycle_specs(resolved_specs)
    stored_overrides, stored_interactives = _split_override_interactive(getstoredoverrides(la))
    merged_overrides = _merge_specs_by_target(stored_overrides, overrides)
    merged_interactives = _merge_interactives_by_target(stored_interactives, interactives)
    new_context = context
    for input in inits
        key = get_target_name(input)
        ov = filter(o -> get_target_name(o) == key, merged_overrides)
        new_context = initcontext(new_context, key; inputs = get_vars(input), overrides = isempty(ov) ? (;) : get_vars(first(ov)))
    end
    new_context = @inline apply_interactive_specs(new_context, merged_interactives)
    new_context = @inline apply_redirect_specs(new_context, la)
    return _with_lifecycle(la, new_context, _merge_specs_by_target(getstoredinits(la), inits), (merged_overrides..., merged_interactives...))
end

"""
    run(la; repeats = 1, lifetime = nothing, inputs...)

Runs `la` once with no process around it and returns `la` with the run's final state context stored in it; the stored
`Init`/`Override` specs are kept. An uninitialized `la` is first initialized (`init(la)`). The run lasts `lifetime`, or
`repeats` repeats when no lifetime is given. The keyword `inputs` are the run's `@input` values: `prepare_for_loop`
checks them against the plan's declarations and adds them to the run's runtime context (`with_inputs`). The runtime
context (inputs, declared locals, returns) is dropped when the run ends; only the state context is kept.
"""
function Base.run(la::LA; repeats = 1, lifetime = nothing, kwargs...) where {LA<:LoopSpec}
    initialized = isnothing(getpersistentcontext(la)) ? init(la) : la
    persistent_context = getpersistentcontext(initialized)
    lt = parse_lifetime(nothing, lifetime, isnothing(lifetime) ? repeats : nothing)
    session, plan, lc = prepare_for_loop(initialized, persistent_context, (; kwargs...), lt, Resuming{false}())
    persistent_context, _ = run_session_loop(session, plan, lc, lt)
    return _with_lifecycle(initialized, persistent_context, getstoredinits(initialized), getstoredoverrides(initialized))
end

"""
    run(plan, context; repeats = 1, lifetime = nothing, inputs...) -> (context, result)

Runs the resolved `plan` (from `setup`) on `context` with no process around it and returns the run's final context and
its result (what the plan's finalizer returns). The run lasts `lifetime`, or `repeats` repeats when no lifetime is
given. The keyword `inputs` are the run's `@input` values, checked against the plan's declarations. The runtime
context (inputs, declared locals, returns) is dropped when the run ends; only the state context comes back.
"""
function Base.run(plan::LA, context::C; repeats = 1, lifetime = nothing, kwargs...) where {LA<:LoopSpec, C<:ProcessContext}
    isresolved(plan) || throw(ArgumentError("run(plan, context) needs the resolved plan that `setup` returns."))
    lt = parse_lifetime(nothing, lifetime, isnothing(lifetime) ? repeats : nothing)
    session, plan, lc = prepare_for_loop(plan, context, (; kwargs...), lt, Resuming{false}())
    return run_session_loop(session, plan, lc, lt)
end

##########################################
########## Hook extensions ###############
##########################################

"""
    prepare_for_loop(plan, context, inputs, lifetime, resume)

A plan run directly (`run(plan)`): a new `InlineSession` for the run (the loop needs a counter; nothing can pause or
close a direct run), the plan, and the `LoopContext` from `context` and the run's inputs (Processes/Hooks.jl).
"""
@inline prepare_for_loop(plan::LA, context::C, inputs::I, lt::LT, resume::Resuming{false}) where {LA<:LoopSpec, C<:ProcessContext, I<:NamedTuple, LT} =
    InlineSession(), plan, (@inline with_inputs((@inline LoopContext(plan, context)), plan, inputs))
