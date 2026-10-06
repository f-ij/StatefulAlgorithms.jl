#=
Which persistent fields one step of a plan can write, worked out from the plan's types.

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

Within one step the runtime context changes from child to child (returns), and a child's view depends on
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
    RC <: ProcessContext || return Any
    return Union{RC, _returned_runtime(Core.Compiler.return_type(_step!, Tuple{A,S,_loop_context_type(C, RC, W),W,N,P,LT}))}
end

"""
The `LoopContext` types a node with wiring view type `W` is stepped with, for stored type `C` and runtime type(s) `RC`
(one per type of a `Union`): in the scope `W` says the node runs in.
"""
Base.@assume_effects :foldable _loop_context_type(@nospecialize(C), @nospecialize(RC), @nospecialize(W)) =
    Union{(LoopContext{C, R, wiring_parent(W)} for R in Base.uniontypes(RC))...}

"""The runtime context type in the `LoopContext` types `rt` a step returns; `Any` for anything else."""
Base.@assume_effects :foldable function _returned_runtime(@nospecialize(rt))
    rt === Union{} && return Union{}
    runtime = Union{}
    for T in Base.uniontypes(rt)
        (T isa DataType && T <: LoopContext) || return Any
        runtime = Union{runtime, runtime_type(T)}
    end
    return runtime
end

"""Append to `exprs` the `_runtime_after` of every leaf under the plan (type `P`) at `plan`, `cursor` and `wiring`, in order."""
function _leaf_runtime_exprs!(exprs, P::Type, plan, cursor, wiring)
    funcs = fieldtype(P, :funcs)
    namespaces = P.parameters[3]
    for i in 1:fieldcount(funcs)
        child, child_cursor, child_wiring = gensym(:child), gensym(:cursor), gensym(:wiring)
        push!(exprs, :(local $child = getfield(getfield($plan, :funcs), $i)),
                     :(local $child_cursor = @inline child_loop_cursor($cursor, Val($i))),
                     :(local $child_wiring = @inline child_wiring_view($wiring, Val($i))))
        if fieldtype(funcs, i) <: AbstractPlan
            _leaf_runtime_exprs!(exprs, fieldtype(funcs, i), child, child_cursor, child_wiring)
        else
            push!(exprs, :(rc = @inline _runtime_after($child, $child_cursor, context, rc, $child_wiring, $(fieldtype(namespaces, i))(), process, lifetime)))
        end
    end
    return exprs
end

"""
    _runtime_by_leaves(plan, cursor, context, RC, wiring, process, lifetime)

The runtime context type after one step of `plan`, given the type `RC` before it, found leaf by leaf: the type is
threaded through every leaf of the plan tree in the order they run, and each leaf is inferred on its own
(`_runtime_after`). `Any` when inference cannot tell.

Unlike inferring the plan's `_step!` as a whole, nothing here infers a method inside a call of the same method:
inference stops following a method that calls itself with an argument type that grows (here the runtime context,
which gains a return with every call until the returns have slots), and then gives up on the whole step. So the tree
is unrolled here, in one generated body, instead of recursing plan by plan.
"""
@inline @generated function _runtime_by_leaves(plan::P, cursor::S, context::C, ::Type{RC}, wiring::W, process::PR, lifetime::LT) where {P<:AbstractPlan,S,C,RC,W,PR,LT}
    exprs = Any[:(rc = RC)]
    _leaf_runtime_exprs!(exprs, P, :plan, :cursor, :wiring)
    push!(exprs, :(return rc))
    return Expr(:block, exprs...)
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
