#=
Which fields of the persistent context one step of a plan can write, worked out from the plan's types.

`_find_writable_fields(node, cursor, persistent_context, RuntimeContextType, wiring, namespace, session, lifetime)` gives the
`(subcontext, field)` pairs one `_step!` of `node` can write, as `Val(written)`. Its arguments are those of the `_step!`
call, except that the runtime context is passed as its type. It follows the plan the way `_step!` does, with the same
child cursors, wiring views and namespaces at each position: the same algorithm can write different fields in
different places, because routes and shares decide where a return goes. It only looks at types; nothing runs, and in a
loop the answer is a compile-time constant.

Rules per node type:
1. an algorithm (`ProcessAlgorithm`, a `Callable` among them): the payload its merge writes, read off the return type of
   `_leaf_payload`, which is built from the same pieces as the algorithm's `_step!` (AlgorithmWrites.jl); a
   `ContextExchange` has its own method (src/Interactive/ContextExchange.jl);
2. a composite, routine or threaded composite: the union over its children (PlanWrites.jl);
3. anything else (below), or a type that inference cannot pin down: every field of the persistent
   context. That is always correct, and as slow as carrying the whole persistent context.

Every method takes all of these arguments; a method that does not need one does not pass it on into its own calls.

What a child's view sees depends on the runtime context, which changes from child to child within one step (each
child's returns are added). So the runtime context type is passed along from child to child: the type after a child is
the union of the type before it and the type its `_step!` returns (`_runtime_context_type_after_node_step`,
RuntimeContextTypes.jl), which can
only make a write set larger, never smaller. A repeated step (a loop, a routine's repeats) sees the same runtime
context type in every repeat: a step removes what it adds (a return lives until the end of its block).
=#

# Rule 3: any other node.
@inline _find_writable_fields(node::NodeType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, session::SessionType, lifetime::LifetimeType) where {NodeType, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, SessionType, LifetimeType} =
    _every_field(PersistentContextType)
