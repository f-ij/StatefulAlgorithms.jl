#=
EXPERIMENTAL: which persistent fields one step of a plan can write, worked out from the plan's types.

`_writes(node, cursor, context, RC, wiring, namespace, process, lifetime)` gives the `(subcontext, field)` pairs one
`_step!` of `node` can write, as `Val(W)`. Its arguments are those of the `_step!` call, except that the runtime
context is passed as its type `RC`. It follows the plan the way `_step!` does, with the same child cursors, wiring
views and namespaces at each position: the same algorithm can write different fields in different places, because
routes and shares decide where a return goes. It only looks at types; nothing runs, and in a loop the answer is a
compile-time constant.

Each node type's rule sits next to its `_step!`:
- a leaf (`ProcessAlgorithm`, ProcessAlgorithmStep.jl): the payload its merge writes, read off the return type of
  `_leaf_payload`, which is built from the same pieces as the leaf's `_step!`; a `FuncWrapper` and a
  `ContextExchange` have their own `_leaf_payload` / `_leaf_writes`;
- a composite, routine or threaded composite (Step.jl, Threaded/Step.jl): the union over its children;
- anything else (the method below), or a type that inference cannot pin down: every field of the context. That is
  always correct, and as slow as carrying the whole context.

Within one step the runtime context changes from child to child (transient outputs), and a child's view depends on
it, so its type is threaded from child to child: the union of the type before a child and the type that child's
`_step!` returns. Repeated steps (a loop, a routine's repeats) use the type it settles on. Both can only make a write
set larger, never smaller.
=#

"""`W` and `new` as one sorted tuple of `(subcontext, field)` pairs without repeats."""
_union_written(W::Tuple, new::Tuple) = Tuple(sort!(unique!(Any[W..., new...]); by = string))

@inline _writes(node::A, cursor::S, context::C, ::Type{RC}, wiring::W, namespace::N, process::P, lifetime::LT) where {A,S,C<:ProcessContext,RC,W,N,P,LT} =
    _every_field(C)

"""Every `(subcontext, field)` pair of the context type `C`, as `Val(W)`."""
@generated function _every_field(::Type{C}) where {C<:ProcessContext}
    D = C.parameters[1]
    W = Tuple((s, f) for s in fieldnames(D) for f in fieldnames(getdatatype(fieldtype(D, s))))
    return :(Val($(_union_written((), W))))
end

"""The union of two write sets."""
@generated _union_writes(::Val{A}, ::Val{B}) where {A,B} = :(Val($(_union_written(A, B))))

"""
The write set read off the type `rt` of a payload `(; subcontext = (; field = value, ...), ...)`, for every type in a
`Union`; every field of `C` when `rt` is not such a named tuple type (for example when inference cannot tell).
"""
Base.@assume_effects :foldable function _payload_writes(@nospecialize(rt), @nospecialize(C))
    rt === Union{} && return _every_field(C)
    written = ()
    for T in Base.uniontypes(rt)
        (T isa DataType && T <: NamedTuple) || return _every_field(C)
        for (subcontext, S) in zip(fieldnames(T), fieldtypes(T))
            (S isa DataType && S <: NamedTuple) || return _every_field(C)
            written = _union_written(written, Tuple((subcontext, field) for field in fieldnames(S)))
        end
    end
    return Val(written)
end

"""
The runtime context type after `_step!(node, ...)` given the type `RC` before it: the union of both, since the node
may not run (a child on an interval). `Any` when inference cannot tell.
"""
@inline function _runtime_after(node::A, cursor::S, context::C, ::Type{RC}, wiring::W, namespace::N, process::P, lifetime::LT) where {A,S,C,RC,W,N,P,LT}
    return Union{RC, _returned_runtime(Core.Compiler.return_type(_step!, Tuple{A,S,C,RC,W,N,P,LT}))}
end

"""The runtime context type in the `(context, runtimecontext)` types `rt`; `Any` for anything else."""
Base.@assume_effects :foldable function _returned_runtime(@nospecialize(rt))
    rt === Union{} && return Union{}
    runtime = Union{}
    for T in Base.uniontypes(rt)
        (T isa DataType && T <: Tuple && length(T.parameters) == 2) || return Any
        runtime = Union{runtime, T.parameters[2]}
    end
    return runtime
end

"""
The runtime context type a repeated `_step!(node, ...)` settles on, starting from `RC`: the union over the repeats.
`Any` when it does not settle within three steps.
"""
@inline function _runtime_fixed_point(node::A, cursor::S, context::C, ::Type{RC}, wiring::W, namespace::N, process::P, lifetime::LT) where {A,S,C,RC,W,N,P,LT}
    r1 = @inline _runtime_after(node, cursor, context, RC, wiring, namespace, process, lifetime)
    r2 = @inline _runtime_after(node, cursor, context, r1, wiring, namespace, process, lifetime)
    r3 = @inline _runtime_after(node, cursor, context, r2, wiring, namespace, process, lifetime)
    return r3 === r2 ? r2 : Any
end
