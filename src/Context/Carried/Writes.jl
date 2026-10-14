#=
Which fields of the persistent context one step of a plan can write, worked out from the plan's types.

`_find_writable_fields(node, cursor, persistent_context, RuntimeContextType, wiring, namespace, process, lifetime)` gives the
`(subcontext, field)` pairs one `_step!` of `node` can write, as `Val(written)`. Its arguments are those of the `_step!`
call, except that the runtime context is passed as its type. It follows the plan the way `_step!` does, with the same
child cursors, wiring views and namespaces at each position: the same algorithm can write different fields in
different places, because routes and shares decide where a return goes. It only looks at types; nothing runs, and in a
loop the answer is a compile-time constant.

Each node type's rule sits next to its `_step!`:
- an algorithm (`ProcessAlgorithm`, ProcessAlgorithmStep.jl): the payload its merge writes, read off the return type of
  `_leaf_payload`, which is built from the same pieces as the algorithm's `_step!`; a `ContextExchange` has its own
  `_find_leaf_writable_fields`;
- a composite, routine or threaded composite (Step.jl, Threaded/Step.jl): the union over its children;
- anything else (the method below), or a type that inference cannot pin down: every field of the persistent context.
  That is always correct, and as slow as carrying the whole persistent context.

What a child's view sees depends on the runtime context, which changes from child to child within one step (each
child's returns are added). So the runtime context type is passed along from child to child: the type after a child is
the union of the type before it and the type its `_step!` returns (`_runtime_context_type_after_node_step`), which can
only make a write set larger, never smaller. A repeated step (a loop, a routine's repeats) sees the same runtime
context type in every repeat: a step removes what it adds (a return lives until the end of its block).
=#

"""`written` and `new` as one sorted tuple of `(subcontext, field)` pairs without repeats."""
_union_written(written::Tuple, new::Tuple) = Tuple(sort!(unique!(Any[written..., new...]); by = string))

@inline _find_writable_fields(node::NodeType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {NodeType, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _every_field(PersistentContextType)

"""Every `(subcontext, field)` pair of the persistent context type, as `Val(written)`."""
@generated function _every_field(::Type{PersistentContextType}) where {PersistentContextType<:ProcessContext}
    subcontexts = PersistentContextType.parameters[1]
    written = Tuple{Symbol, Symbol}[]
    for s in fieldnames(subcontexts), f in fieldnames(getdatatype(fieldtype(subcontexts, s)))
        push!(written, (s, f))
    end
    return :(Val($(_union_written((), Tuple(written)))))
end

"""The union of two write sets."""
@generated _merge_writable_fields(::Val{A}, ::Val{B}) where {A,B} = :(Val($(_union_written(A, B))))

"""
The write set read off the type `payload_type` of a payload `(; subcontext = (; field = value, ...), ...)`, for every
type in a `Union`; every field of the persistent context type when `payload_type` is not such a named tuple type (for
example when inference cannot tell).
"""
Base.@assume_effects :foldable function _read_payload_fields(@nospecialize(payload_type), @nospecialize(PersistentContextType))
    payload_type === Union{} && return _every_field(PersistentContextType)
    written = ()
    for T in Base.uniontypes(payload_type)
        (T isa DataType && T <: NamedTuple) || return _every_field(PersistentContextType)
        for (subcontext, S) in zip(fieldnames(T), fieldtypes(T))
            (S isa DataType && S <: NamedTuple) || return _every_field(PersistentContextType)
            written = _union_written(written, Tuple((subcontext, field) for field in fieldnames(S)))
        end
    end
    return Val(written)
end

#=
Runtime context types, from inference. Used for the write sets above and for typing the runtime context before the
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
@inline function _runtime_context_type_after_node_step(node::NodeType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {NodeType, CursorType, PersistentContextType, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType}
    RuntimeContextType <: ProcessContext || return Any
    stepped = Core.Compiler.return_type(_step!, Tuple{NodeType, CursorType, _loop_context_type(PersistentContextType, RuntimeContextType, WiringViewType), WiringViewType, NamespaceType, ProcessType, LifetimeType})
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
