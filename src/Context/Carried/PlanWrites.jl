#=
Rule 2 of `_find_writable_fields` (see Writes.jl): a composite, routine or threaded composite writes the union of what
its children write, each child asked at its own cursor, wiring view and namespace, with the runtime context type passed
from child to child (RuntimeContextTypes.jl).

What a plan's rule emits (`_children_writes_expr`; `child1`, `cursor1`, ... are gensyms, the three locals per child are
those of `_child_setup_exprs` in src/LoopAlgorithms/Step.jl):

       local writes = Val(())
       local runtime_context_type = RuntimeContextType
       local algos = getalgos(plan)
       # child 1, a leaf: the three locals, then
       writes = _merge_writable_fields(writes, _find_writable_fields(child1, cursor1, persistent_context, runtime_context_type, wiring1, Namespace1(), session, lifetime))
       runtime_context_type = _runtime_context_type_after_node_step(child1, cursor1, persistent_context, runtime_context_type, wiring1, Namespace1(), session, lifetime)
       # child 2, a plan: the three locals, then these lines for child 2's children, here, then
       runtime_context_type = _runtime_context_type_after_leaving(runtime_context_type, typeof(wiring2))
       return writes
=#

"""
    _children_writes_expr(PlanType)

Return the body of the generated `_find_writable_fields` for a plan that steps its children in order (a composite, routine or
threaded composite); see "What a plan's rule emits" in the file header. The body returns the union of the persistent fields its children write,
each child asked at its own cursor, wiring view and namespace.

The runtime context type is passed from child to child as `_step!` passes the runtime context. A child that repeats is
asked once, with the type before its first repeat: a step removes what it adds, so the type is the same in every repeat,
except a local declared without a type that gets its first value in a repeat (Locals.jl, section 3). Nested plans are written inline, for the
same reason as in `_plan_step_exprs`: a nested `_find_writable_fields` call would be the same method with a growing runtime
context type, which inference stops following.
"""
function _children_writes_expr(PlanType::Type)
    exprs = Any[:(local writes = Val(())), :(local runtime_context_type = RuntimeContextType)]
    _children_writes_exprs!(exprs, PlanType, :plan, :cursor, :wiring)
    push!(exprs, :(return writes))
    return Expr(:block, exprs...)
end

"""
Append to `exprs` the lines that add the writes of each child of `plan` (type `PlanType`) to `writes` and update
`runtime_context_type`; a nested plan's children are appended in its place. See `_children_writes_expr`.
"""
function _children_writes_exprs!(exprs, PlanType::Type, plan, cursor, wiring)
    child_namespace_tuple_type = PlanType.parameters[3]
    children = fieldtype(PlanType, :funcs)
    algos = gensym(:algos)
    push!(exprs, :(local $algos = @inline getalgos($plan)))
    for i in 1:numalgos(PlanType)
        ChildType = fieldtype(children, i)
        child_namespace = :($(fieldtype(child_namespace_tuple_type, i))())
        setup, child, child_cursor, child_wiring = _child_setup_exprs(algos, cursor, wiring, i)
        append!(exprs, setup)
        if steps_inline(ChildType)
            # The nested plan's writes, inline, with the runtime context type passed through its children; when it
            # ends its returns are removed, so the type afterwards is the one before it, also over repeats. Nothing
            # here asks what a plan's `_step!` returns: that would be the self-call inference stops following.
            _children_writes_exprs!(exprs, ChildType, child, child_cursor, child_wiring)
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_leaving(runtime_context_type, typeof($child_wiring))))
        else
            push!(exprs, :(writes = @inline _merge_writable_fields(writes, (@inline _find_writable_fields($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $child_namespace, session, lifetime)))))
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_node_step($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $child_namespace, session, lifetime)))
        end
    end
    return exprs
end

# The persistent fields a composite or routine writes in one step.
@inline @generated _find_writable_fields(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, session::SessionType, lifetime::LifetimeType) where {PlanType<:CompositeAlgorithm, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, SessionType, LifetimeType} =
    _children_writes_expr(PlanType)
@inline @generated _find_writable_fields(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, session::SessionType, lifetime::LifetimeType) where {PlanType<:Routine, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, SessionType, LifetimeType} =
    _children_writes_expr(PlanType)

# The persistent fields a threaded composite writes: as a composite's.
@inline @generated _find_writable_fields(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, session::SessionType, lifetime::LifetimeType) where {PlanType<:ThreadedCompositeAlgorithm, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, SessionType, LifetimeType} =
    _children_writes_expr(PlanType)
