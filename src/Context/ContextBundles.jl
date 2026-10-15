#=
Context bundles: what the code around a step or an init works on, as one value. A bundle holds the persistent context
(the subcontexts that persist: algorithms' and states' state) and what goes with it in that phase. Views are made from a
bundle and ask it for anything beyond the persistent context, by dispatch on its type. Internal: users see
`ProcessContext`s.

The two contexts of a loop are named apart everywhere: the persistent context (`getpersistent`, a variable
`persistent_context`) and the runtime context (`getruntime`, a variable `runtime_context`).
=#

abstract type ContextBundle end

"""
    LoopContext(persistent_context, runtime_context)

What one step of a loop works on: the persistent context, the runtime context (inputs, declared locals, captured and
subcontext returns; see ContextParts.jl), and the plan node whose scope it is in (`Node`, its `PlanWiring` type, or
`Nothing` outside every node; see `Scope` for the declared locals and captured returns visible by name, and
`PlanWiringView` for why a node is named by its type). Steps take one and return one.

A plan node is a scope. Stepping it enters its scope (`enter_scope`): its names become visible and its returns are
unset, so a return lives for one step of the node that captures it. Leaving it (`leave_scope`) puts back the enclosing
scope: the node's declared locals keep their values for the run, its returns are no longer visible. A `LoopContext`
made from just a persistent and a runtime context is in no scope, as at the start of a step of the loop.

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
"""A `LoopContext` in the scope of the plan node `Node` (its `PlanWiring` type, or `Nothing` for none)."""
@inline LoopContext(persistent_context::PersistentContextType, runtime_context::RuntimeContextType, ::Type{Node}) where {PersistentContextType<:ProcessContext, RuntimeContextType<:ProcessContext, Node} =
    LoopContext{PersistentContextType, RuntimeContextType, Node}(persistent_context, runtime_context)

"""
    InitContext(persistent_context, algo, lifetime)

What init works on: the persistent context being built, plus what init may ask about the run it prepares, the algorithm
and its lifetime (`processsizehint!` sizes a buffer by the number of steps). No runtime context: init runs before there
are runtime values.
"""
struct InitContext{PersistentContextType<:ProcessContext, AlgoType, LifetimeType} <: ContextBundle
    persistent::PersistentContextType
    algo::AlgoType
    lifetime::LifetimeType
end

"""The persistent context of a bundle."""
@inline getpersistent(bundle::ContextBundle) = getfield(bundle, :persistent)
"""The runtime context of a `LoopContext`."""
@inline getruntime(lc::LoopContext) = getfield(lc, :runtime)
@inline getregistry(bundle::ContextBundle) = @inline getregistry(getpersistent(bundle))
@inline init_lifetime(ic::InitContext) = getfield(ic, :lifetime)

"""The scope a bundle is in: a `LoopContext`'s (see `Scope`); init is in none."""
bundle_scope(::Type{<:LoopContext{PersistentContextType, RuntimeContextType, Node}}) where {PersistentContextType, RuntimeContextType, Node} = node_scope(Node)
bundle_scope(::Type{<:InitContext}) = NoScope

"""The bundle with another persistent context, or (a `LoopContext`) another persistent and runtime context, in the same scope."""
@inline withpersistent(lc::LoopContext{PersistentContextType, RuntimeContextType, Node}, persistent_context::ProcessContext) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(persistent_context, getruntime(lc), Node)
@inline withcontexts(::LoopContext{PersistentContextType, RuntimeContextType, Node}, persistent_context::ProcessContext, runtime_context::ProcessContext) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(persistent_context, runtime_context, Node)
@inline withpersistent(ic::InitContext, persistent_context::ProcessContext) = InitContext(persistent_context, getfield(ic, :algo), getfield(ic, :lifetime))

"""The persistent context type of a bundle type, and the runtime context type of a `LoopContext` type."""
persistent_type(::Type{<:LoopContext{PersistentContextType}}) where {PersistentContextType} = PersistentContextType
persistent_type(::Type{<:InitContext{PersistentContextType}}) where {PersistentContextType} = PersistentContextType
runtime_type(::Type{<:LoopContext{PersistentContextType, RuntimeContextType}}) where {PersistentContextType, RuntimeContextType} = RuntimeContextType

"""A bundle for a persistent context on its own, with no runtime values (looking at a context outside a loop)."""
@inline bundle_of(persistent_context::ProcessContext) = LoopContext(persistent_context, _empty_context())

# Runtime values (ContextParts.jl): a `LoopContext` has them, an `InitContext` none.
@inline _runtime_values(lc::LoopContext, name::Val) = @inline _runtime_values(getruntime(lc), name)
@inline _runtime_values(::InitContext, ::Val) = (;)

@inline get_part_data(lc::LoopContext, part::ContextPart) = @inline get_part_data(getruntime(lc), part)
@inline get_part_data(::InitContext, ::ContextPart) = (;)

"""What `finalstep` gets: the loop's persistent and runtime values as one `ProcessContext` (see `_visible_context`)."""
@inline visible_context(lc::LoopContext) = @inline _visible_context(getpersistent(lc), getruntime(lc))

"""The lifetime of the run being prepared: only while init runs (for sizing); steps do not see it."""
@inline bundle_lifetime(ic::InitContext) = init_lifetime(ic)
bundle_lifetime(::LoopContext) = error("The lifetime is only known while init runs (for sizing, e.g. `processsizehint!`); steps do not see it.")

"""
The bundle after a merge: `persistent_context` as the new persistent context, and the runtime values in
`runtime_patch` (`(; part = (; name = value, ...), ...)`) merged into the runtime context. An init merge has no runtime
values.
"""
@inline _rebundle(lc::LoopContext, persistent_context::ProcessContext, runtime_patch::NamedTuple) =
    @inline withcontexts(lc, persistent_context, (@inline merge_runtime_returns(getruntime(lc), runtime_patch)))
@inline _rebundle(ic::InitContext, persistent_context::ProcessContext, ::NamedTuple{()}) = withpersistent(ic, persistent_context)

"""
    enter_scope(lc, wiring)

`lc` in the scope of the plan node whose wiring view is `wiring`: the node's names visible, and its captured returns
and the subcontext returns of the algorithms directly in it unset (see `LoopContext`). Typed slots (Outputs.jl) are
made unset; a return without a slot is removed.
"""
@inline enter_scope(lc::LoopContext, wiring::PlanWiringView{Root, WiringType}) where {Root, WiringType<:PlanWiring} =
    LoopContext(getpersistent(lc), (@inline _unset_returns(getruntime(lc), Val(node_resets(WiringType)))), WiringType)

"""`inner` (a `LoopContext` after the steps of a scope) back in the scope of `outer`."""
@inline leave_scope(inner::LoopContext, ::LoopContext{PersistentContextType, RuntimeContextType, Node}) where {PersistentContextType, RuntimeContextType, Node} =
    LoopContext(getpersistent(inner), getruntime(inner), Node)
