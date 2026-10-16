#=
Context bundles: everything a step (or init) can read and write, packed into one value.

During a loop there are two contexts. The persistent context holds the state of every algorithm and lives for the whole
run. The runtime context holds values that only exist while the loop runs: inputs, declared locals and returns. A
bundle carries both, plus whatever else the phase needs (see `LoopContext` and `InitContext`). Views are made from a
bundle. Bundles are internal: users only ever see `ProcessContext`s.

Names used everywhere: `getpersistent` / `persistent_context` for the persistent context, `getruntime` /
`runtime_context` for the runtime context.
=#

abstract type ContextBundle end

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
    InitContext(persistent_context, algo, lifetime)

What init works on. Init runs before the loop starts, so there is no runtime context yet.

It holds the persistent context that init is filling in, the algorithm being prepared, and the run's lifetime. The
lifetime is there so init can size buffers by the number of steps (`processsizehint!`).
"""
struct InitContext{PersistentContextType<:ProcessContext, AlgoType, LifetimeType} <: ContextBundle
    persistent::PersistentContextType
    algo::AlgoType
    lifetime::LifetimeType
end

"""Returns the bundle's persistent context."""
@inline getpersistent(bundle::ContextBundle) = getfield(bundle, :persistent)
"""Returns the bundle's runtime context. Only a `LoopContext` has one."""
@inline getruntime(lc::LoopContext) = getfield(lc, :runtime)
@inline getregistry(bundle::ContextBundle) = @inline getregistry(getpersistent(bundle))
@inline init_lifetime(ic::InitContext) = getfield(ic, :lifetime)

"""Returns the `Scope` type of the plan node a bundle is in. Init is never in a node, so it gets `NoScope`."""
bundle_scope(::Type{<:LoopContext{PersistentContextType, RuntimeContextType, Node}}) where {PersistentContextType, RuntimeContextType, Node} = node_scope(Node)
bundle_scope(::Type{<:InitContext}) = NoScope

"""
Copies a bundle with its persistent context swapped (`withpersistent`), or both its contexts swapped
(`withcontexts`, `LoopContext` only). The copy stays in the same scope.
"""
@inline withpersistent(lc::LoopContext{PersistentContextType, RuntimeContextType, Node}, persistent_context::ProcessContext) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(persistent_context, getruntime(lc), Node)
@inline withcontexts(::LoopContext{PersistentContextType, RuntimeContextType, Node}, persistent_context::ProcessContext, runtime_context::ProcessContext) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(persistent_context, runtime_context, Node)
@inline withpersistent(ic::InitContext, persistent_context::ProcessContext) = InitContext(persistent_context, getfield(ic, :algo), getfield(ic, :lifetime))

"""Return the type of a bundle type's persistent context (`persistent_type`) or runtime context (`runtime_type`)."""
persistent_type(::Type{<:LoopContext{PersistentContextType}}) where {PersistentContextType} = PersistentContextType
persistent_type(::Type{<:InitContext{PersistentContextType}}) where {PersistentContextType} = PersistentContextType
runtime_type(::Type{<:LoopContext{PersistentContextType, RuntimeContextType}}) where {PersistentContextType, RuntimeContextType} = RuntimeContextType

"""Wraps a persistent context in a bundle with an empty runtime context, for looking at a context outside a loop."""
@inline bundle_of(persistent_context::ProcessContext) = LoopContext(persistent_context, _empty_context())

"""
Return values from a bundle's runtime context: one runtime context partition (`get_runtime_partition(bundle,
CapturedReturns())`), or the values filed under a subcontext name (`_runtime_values(bundle, Val(:_captured_returns))`).
Init has no runtime context, so it always gets an empty named tuple.
"""
@inline _runtime_values(lc::LoopContext, name::Val) = @inline _runtime_values(getruntime(lc), name)
@inline _runtime_values(::InitContext, ::Val) = (;)
@inline get_runtime_partition(lc::LoopContext, partition::RuntimePartition) = @inline get_runtime_partition(getruntime(lc), partition)
@inline get_runtime_partition(::InitContext, ::RuntimePartition) = (;)

"""
    final_context(lc::LoopContext)

Returns everything a loop holds at its end as one `ProcessContext`. A `finalstep` (`@finally`) gets it; without one, it
is the run's result (`fetch(p)`, `p.lastresult`). It is the persistent context with the runtime context shown in it:
1. each namespace's subcontext returns are merged into that namespace's subcontext, so `ctx.Sensor_1.extra` reads one;
   a return with the name of a state variable shows instead of that variable
2. the inputs, declared locals and captured returns are added as the subcontexts `_inputs`, `_declared_locals` and
   `_captured_returns`, in the order a run's runtime context has them

A return shows the value of the last step that wrote it, or `nothing` if no step did. The persistent context the loop
stores does not change.
"""
@inline function final_context(lc::LoopContext)
    runtime_context = @inline getruntime(lc)
    returns = map(r -> map(_final_value, r), (@inline get_subcontext_returns(runtime_context)))
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
_shown_values(::CapturedReturns, values::NT) where {NT<:NamedTuple} = map(_final_value, values)

"""Returns the lifetime of the run being prepared. Only init can ask for it (to size buffers). A step that asks gets an error."""
@inline bundle_lifetime(ic::InitContext) = init_lifetime(ic)
bundle_lifetime(::LoopContext) = error("The lifetime is only known while init runs (for sizing, e.g. `processsizehint!`); steps do not see it.")

"""
    _rebundle(bundle, persistent_context, runtime_patch)

Builds the bundle a step continues with, after one algorithm's return has been written back. The state it wrote is
already in `persistent_context`, which replaces the old one; the runtime values it wrote (declared locals, returns) are
in `runtime_patch` and are written into the runtime context.

`runtime_patch` is grouped by runtime context partition: `(; _declared_locals = (; x = 1.0), _captured_returns = (; y = 2))`.
During init there is no runtime context, so the patch is always empty there.
"""
@inline _rebundle(lc::LoopContext, persistent_context::ProcessContext, runtime_patch::NamedTuple) =
    @inline withcontexts(lc, persistent_context, (@inline merge_runtime_returns(getruntime(lc), runtime_patch)))
@inline _rebundle(ic::InitContext, persistent_context::ProcessContext, ::NamedTuple{()}) = withpersistent(ic, persistent_context)

"""
    enter_scope(lc, wiring)

Moves `lc` into the scope of a plan node (the node `wiring` belongs to), at the start of a step of that node. The
node's names become visible, and the returns it captures are cleared, along with the returns of the algorithms
directly in it. A return with a typed slot (a `Maybe` field, Outputs.jl) is emptied; a return without one is
removed.
"""
@inline enter_scope(lc::LoopContext, wiring::PlanWiringView{Root, WiringType}) where {Root, WiringType<:PlanWiring} =
    LoopContext(getpersistent(lc), (@inline _unset_returns(getruntime(lc), Val(node_resets(WiringType)))), WiringType)

"""
Moves `inner` back into the scope of `outer`, after a node's steps are done. It keeps the values `inner` holds and
only changes the scope.
"""
@inline leave_scope(inner::LoopContext, ::LoopContext{PersistentContextType, RuntimeContextType, Node}) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(getpersistent(inner), getruntime(inner), Node)
