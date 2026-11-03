#=
Extendable API of context bundles: what views and steps ask a bundle, where the answer depends on the bundle type.

Each function here has the default every bundle gets, which is the answer for a bundle with no runtime context and no
plan node (`InitContext`). Extended in:
- Bundles/LoopContext.jl: its plan node's scope, and the values in its runtime context;
- Bundles/InitContext.jl: the lifetime of the run being prepared.
=#

"""Returns the `Scope` type of the plan node a bundle is in. `NoScope` by default: init is never in a node."""
bundle_scope(::Type{B}) where {B<:ContextBundle} = NoScope

"""
Return values from a bundle's runtime context: one runtime context partition (`get_runtime_partition(bundle,
CapturedReturns())`), or the values filed under a subcontext name (`runtime_values(bundle, Val(:_captured_returns))`).
An empty named tuple by default: a bundle without a runtime context (init) has none.
"""
@inline runtime_values(::B, ::Val) where {B<:ContextBundle} = (;)
@inline get_runtime_partition(::B, ::RuntimePartition) where {B<:ContextBundle} = (;)

"""
Returns the lifetime of the run being prepared. Only init can ask for it (to size buffers, e.g. `processsizehint!`).
By default, an error: steps do not see it.
"""
bundle_lifetime(::B) where {B<:ContextBundle} = error("The lifetime is only known while init runs (for sizing, e.g. `processsizehint!`); steps do not see it.")
