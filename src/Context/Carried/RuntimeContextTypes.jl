#=
Runtime context types, from inference. Used for the write sets of plans (PlanWrites.jl) and for typing the runtime context before the
loop (Outputs.jl).

The helpers that take types as arguments are `@nospecialize` and `Base.@assume_effects :foldable`. `@nospecialize`
compiles them once for all argument types instead of once per plan. `:foldable` promises that they are pure (no side
effects, they terminate, same result for the same arguments), so when their arguments are known while compiling (they
always are here: they are the plan's types) the compiler evaluates them while compiling and uses the resulting type.
Without the promise it cannot prove that, the type is only known at run time, the `return_type` question that uses it
cannot be answered, and the loop falls back to dynamic dispatch.
=#

"""
The runtime context type after `_step!(node, ...)`, given the type `RuntimeContextType` before it: the union of both,
since the node may not run in a step (a child on an interval). `Any` when inference cannot tell.
"""
@inline function _runtime_context_type_after_node_step(node::NodeType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, session::SessionType, lifetime::LifetimeType) where {NodeType, CursorType, PersistentContextType, RuntimeContextType, WiringViewType, NamespaceType, SessionType, LifetimeType}
    RuntimeContextType <: ProcessContext || return Any
    stepped = Core.Compiler.return_type(_step!, Tuple{NodeType, CursorType, _loop_context_type(PersistentContextType, RuntimeContextType, WiringViewType), WiringViewType, NamespaceType, SessionType, LifetimeType})
    return Union{RuntimeContextType, _runtime_context_types_of(stepped)}
end

"""
The `LoopContext` types a node with wiring view type `WiringViewType` is stepped with, for the persistent context type
and the runtime context type(s) (one `LoopContext` type per type of a `Union`), in the scope the wiring view says the
node runs in.
"""
Base.@assume_effects :foldable _loop_context_type(@nospecialize(PersistentContextType), @nospecialize(RuntimeContextType), @nospecialize(WiringViewType)) =
    Union{(LoopContext{PersistentContextType, R, read_parent_wiring_type(WiringViewType)} for R in Base.uniontypes(RuntimeContextType))...}

"""The runtime context type(s) in the `LoopContext` types `loopcontext_types` a step returns; `Any` for anything else."""
Base.@assume_effects :foldable function _runtime_context_types_of(@nospecialize(loopcontext_types))
    loopcontext_types === Union{} && return Union{}
    runtime_context_types = Union{}
    for T in Base.uniontypes(loopcontext_types)
        (T isa DataType && T <: LoopContext) || return Any
        runtime_context_types = Union{runtime_context_types, runtime_type(T)}
    end
    return runtime_context_types
end

"""
Return the runtime context type after a plan node ends: `RuntimeContextType` (the type at the node's end) without the
node's returns, as `leave_scope` removes them. `WiringViewType` is the type of the node's wiring view. `Any` when
`RuntimeContextType` is not a `ProcessContext` type.
"""
Base.@assume_effects :foldable _runtime_context_type_after_leaving(@nospecialize(RuntimeContextType), @nospecialize(WiringViewType)) =
    RuntimeContextType <: ProcessContext ? Core.Compiler.return_type(_strip_returns, Tuple{RuntimeContextType, Val{node_resets(_view_node(WiringViewType))}}) : Any
"""The `PlanWiring` type of the node a wiring view type points at."""
_view_node(::Type{<:PlanWiringView{Root, WiringType}}) where {Root, WiringType} = WiringType
