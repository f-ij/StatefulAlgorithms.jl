"""
    LoopContext(persistent_context, runtime_context)

What a step works on while the loop runs. Every step takes one and returns an updated one.

It holds the persistent context, the runtime context, and (as the type parameter `Node`) the plan node whose scope the
step is in. The scope decides which declared locals and captured returns a step can see by name. `Node` is the node's
`PlanWiring` type, or `Nothing` when the bundle is in no node, as at the start of a loop step.

Every plan node is a scope. Entering it (`enter_scope`) makes its names visible and clears its returns, so a return
only lasts for one step of the node that captures it. Leaving it (`leave_scope`) goes back to the enclosing scope: the
node's declared locals keep their values for the rest of the run, its returns are no longer visible.

The loop never carries a `LoopContext` from one step to the next: it carries only the persistent fields its steps
write and the runtime context, and builds the `LoopContext` again at the start of every step (see Carried/Carry.jl).
Building it costs nothing once compiled, and the fields no step writes are read where they already are instead of
being copied.
"""
struct LoopContext{PersistentContextType<:ProcessContext, RuntimeContextType<:ProcessContext, Node} <: ContextBundle
    persistent::PersistentContextType
    runtime::RuntimeContextType
    LoopContext{PersistentContextType, RuntimeContextType, Node}(persistent::PersistentContextType, runtime::RuntimeContextType) where {PersistentContextType<:ProcessContext, RuntimeContextType<:ProcessContext, Node} =
        new{PersistentContextType, RuntimeContextType, Node}(persistent, runtime)
end
LoopContext(persistent_context::PersistentContextType, runtime_context::RuntimeContextType) where {PersistentContextType<:ProcessContext, RuntimeContextType<:ProcessContext} =
    LoopContext{PersistentContextType, RuntimeContextType, Nothing}(persistent_context, runtime_context)
"""Makes a `LoopContext` that is in the scope of plan node `Node` (its `PlanWiring` type, or `Nothing` for no node)."""
@inline LoopContext(persistent_context::PersistentContextType, runtime_context::RuntimeContextType, ::Type{Node}) where {PersistentContextType<:ProcessContext, RuntimeContextType<:ProcessContext, Node} =
    LoopContext{PersistentContextType, RuntimeContextType, Node}(persistent_context, runtime_context)


"""
    LoopContext(plan, context)

The `LoopContext` a new run starts from, before its inputs are added (`with_inputs`): `context` as its persistent
context and, as its runtime context, the plan's declared locals (`_declared_locals`). Made where a run is handed to the
loop (`prepare_for_loop`: a `Process` run, an `InlineProcess` run, the manager's inline run, `run(plan)`). A paused run
that resumes does not use it: it gets `LoopContext(context, runtime_context)` with the runtime context its pause kept.

Returns (`_captured_returns`, `_subcontext_returns`) are not in it: a step adds them where they are assigned and removes
them when their plan node ends (see `LoopContext`), so every step gets and returns a runtime context of this type.

The process (now its session) and the lifetime are not in it: no step read them (they were in `_captured_returns` until
2026-10). Init still gets the lifetime, for sizing (`InitContext`, `processsizehint!`). To give steps loop information
again (step index, total steps, elapsed time, a stop request), add narrow read-only values here rather than the session
(`ProcessSession`), which would tie step code to the session type; most of those uses belong in the plan (schedules,
lifetimes) instead.
"""
@inline function LoopContext(plan::A, context::C) where {A, C<:ProcessContext}
    locals = collect_tree_locals(plan)
    runtime = isempty(locals) ? (@inline _empty_context()) :
              (@inline with_subcontext(_empty_context(), Val(:_declared_locals), SubContext{:_declared_locals}(locals)))
    return LoopContext(context, runtime)
end

"""Returns the bundle's runtime context. Only a `LoopContext` has one."""
@inline getruntime(lc::LoopContext) = getfield(lc, :runtime)
"""Returns the type of a `LoopContext` type's runtime context."""
runtime_type(::Type{<:LoopContext{PersistentContextType, RuntimeContextType}}) where {PersistentContextType, RuntimeContextType} = RuntimeContextType

"""Copies a `LoopContext` with both its contexts swapped. The copy stays in the same scope."""
@inline withcontexts(::LoopContext{PersistentContextType, RuntimeContextType, Node}, persistent_context::ProcessContext, runtime_context::ProcessContext) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(persistent_context, runtime_context, Node)

"""Wraps a persistent context in a bundle with an empty runtime context, for looking at a context outside a loop."""
@inline bundle_of(persistent_context::ProcessContext) = LoopContext(persistent_context, _empty_context())

# Interface.jl
persistent_type(::Type{<:LoopContext{PersistentContextType}}) where {PersistentContextType} = PersistentContextType
@inline withpersistent(lc::LoopContext{PersistentContextType, RuntimeContextType, Node}, persistent_context::ProcessContext) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(persistent_context, getruntime(lc), Node)
@inline _rebundle(lc::LoopContext, persistent_context::ProcessContext, runtime_patch::NamedTuple) =
    @inline withcontexts(lc, persistent_context, (@inline merge_runtime_returns(getruntime(lc), runtime_patch)))

# Hooks.jl
bundle_scope(::Type{<:LoopContext{PersistentContextType, RuntimeContextType, Node}}) where {PersistentContextType, RuntimeContextType, Node} = node_scope(Node)
@inline runtime_values(lc::LoopContext, name::Val) = @inline runtime_values(getruntime(lc), name)
@inline get_runtime_partition(lc::LoopContext, partition::RuntimePartition) = @inline get_runtime_partition(getruntime(lc), partition)

"""
    final_context(lc::LoopContext)

Returns everything a loop holds at its end as one `ProcessContext`. A `finalstep` (`@finally`) gets it; without one, it
is the run's result (`fetch(p)`, `p.lastresult`). It is the persistent context with the runtime context shown in it:
1. each namespace's subcontext returns are merged into that namespace's subcontext, so `ctx.Sensor_1.extra` reads one;
   a return with the name of a state variable shows instead of that variable
2. the inputs, declared locals and captured returns are added as the subcontexts `_inputs`, `_declared_locals` and
   `_captured_returns`, in the order a run's runtime context has them

At the end of a run only the inputs and declared locals are left: a block's returns are removed when the block ends.
Returns show only when it is built inside a run, by the routine stop checks. The persistent context the loop stores
does not change.
"""
@inline function final_context(lc::LoopContext)
    runtime_context = @inline getruntime(lc)
    returns = map(r -> map(shown_value, r), (@inline get_subcontext_returns(runtime_context)))
    shown = @inline merge_into_subcontexts((@inline getpersistent(lc)), returns)
    shown = @inline _show_partition(shown, runtime_context, Inputs())
    shown = @inline _show_partition(shown, runtime_context, DeclaredLocals())
    return @inline _show_partition(shown, runtime_context, CapturedReturns())
end

"""
Returns `pc` with one partition of `runtime_context` added as the subcontext of that partition's name, or `pc` itself
when `runtime_context` does not have that partition.
"""
@inline function _show_partition(pc::PC, runtime_context::RC, partition::P) where {PC<:ProcessContext, RC<:ProcessContext, P<:RuntimePartition}
    name = runtime_partition_name(partition)
    haskey(get_subcontexts(runtime_context), name) || return pc
    values = _shown_values(partition, (@inline get_runtime_partition(runtime_context, partition)))
    return @inline with_subcontext(pc, Val(name), SubContext{name}(values))
end

"""Returns a partition's values as the visible context shows them: captured returns unwrapped from their slots, the rest as stored."""
_shown_values(::P, values::NT) where {P<:RuntimePartition, NT<:NamedTuple} = values
_shown_values(::CapturedReturns, values::NT) where {NT<:NamedTuple} = map(shown_value, values)

"""
    enter_scope(lc, wiring)

`lc` in the scope of the plan node whose wiring view is `wiring`: the node's names become visible. Nothing of the
node's own is in the runtime context yet: its returns are added at the line that writes them (see `LoopContext`).
"""
@inline enter_scope(lc::LoopContext, wiring::PlanWiringView{Root, WiringType}) where {Root, WiringType<:PlanWiring} =
    LoopContext(getpersistent(lc), getruntime(lc), WiringType)

"""
`inner` (a `LoopContext` after the steps of a scope) back in the scope of `outer`: the returns of the node (its
captured returns, and the subcontext returns of the algorithms directly in it) are removed, so nothing after the node
sees them, and the runtime context has the type it had before the node.
"""
@inline leave_scope(inner::LoopContext{PersistentContextType, InnerRuntimeContextType, InnerNode}, ::LoopContext{OuterPersistentContextType, RuntimeContextType, Node}) where {PersistentContextType, InnerRuntimeContextType, InnerNode, OuterPersistentContextType, RuntimeContextType, Node} =
    LoopContext(getpersistent(inner), (@inline _strip_returns(getruntime(inner), Val(node_resets(InnerNode)))), Node)
