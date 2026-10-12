"""
Running a composite algorithm allows for static unrolling and inlining of all sub-algorithms through 
    recursive calls
"""


#=
Stepping a plan, with its nested plans written inline.

The code of one plan's step is generated here as a list of expressions, and a nested composite or routine is not
stepped by calling `_step!` for it but written into the same body (`_plan_step_exprs` calls itself while generating).
Why: the runtime context grows within a step (each return is added at the line that writes it, and removed when its
plan node ends, see `leave_scope`), so a nested plan gets a larger `LoopContext` type than its parent. A nested plan's
`_step!` is the same method as its parent's, and Julia's inference stops following a method that calls itself with a
growing argument type: the call becomes dynamic. Written inline, nothing calls itself, and every line has its exact type.

Children on a schedule (`@every n`) run in a branch: consecutive children on the same schedule share one (an
algorithm and the call that captures its return are such a pair). After the branch the runtime context has one type
whether it ran or not (`_conditional_step`): the fields it had before, a field the branch assigned with another type
as the union of both (`y = nothing`, then `y = @every 2 f()`), and nothing the branch added. The DSL only lets a
scheduled statement assign a name that exists before it, so what the branch adds is internal (an algorithm's
return, read by its capture in the same branch).
=#

"""Whether a child is stepped inline (its body written into its parent's step) rather than by calling `_step!` for it."""
_steps_inline(::Type) = false
_steps_inline(::Type{<:Union{CompositeAlgorithm, Routine}}) = true

"""Whether a composite schedule entry runs in every step (known from its type)."""
_always_runs(::Interval{1}) = true
_always_runs(::Integer) = false
_always_runs(::Any) = false

"""The expressions that step `plan` (of type `PlanType`, cursor `cursor`, wiring view `wiring`), taking and assigning the `LoopContext` variable `lc`."""
_plan_step_exprs(PlanType::Type{<:CompositeAlgorithm}, plan, cursor, wiring, lc) = _composite_step_exprs(PlanType, plan, cursor, wiring, lc)
_plan_step_exprs(PlanType::Type{<:Routine}, plan, cursor, wiring, lc) = _routine_step_exprs(PlanType, plan, cursor, wiring, lc)

"""The expressions that step one child: inline for a nested plan, a `_step!` call for anything else."""
function _child_step_exprs(ChildType::Type, child, cursor, wiring, namespace_expr, lc)
    _steps_inline(ChildType) && return _plan_step_exprs(ChildType, child, cursor, wiring, lc)
    return Any[:($lc = @inline _step!($child, $cursor, $lc, $wiring, $namespace_expr, process, lifetime))]
end

"""The local variables for child `i` of a plan: its value, cursor and wiring view."""
function _child_setup_exprs(plan_algos, cursor, wiring, i)
    child, child_cursor, child_wiring = gensym(:child), gensym(:cursor), gensym(:wiring)
    setup = Any[:(local $child = @inline getfield($plan_algos, $i)),
                :(local $child_cursor = @inline child_loop_cursor($cursor, Val($i))),
                :(local $child_wiring = @inline child_wiring_view($wiring, Val($i)))]
    return setup, child, child_cursor, child_wiring
end

function _composite_step_exprs(PlanType::Type, plan, cursor, wiring, lc)
    schedule_values = PlanType.parameters[2]
    namespace_types = PlanType.parameters[3]
    children = fieldtype(PlanType, :funcs)
    algos, this_inc, outer = gensym(:algos), gensym(:inc), gensym(:outer)
    exprs = Any[:(local $algos = @inline getalgos($plan)), :(local $this_inc = @inline inc($cursor)),
                :(local $outer = $lc), :($lc = @inline enter_scope($lc, $wiring))]
    i = 1
    while i <= fieldcount(children)
        schedule_value = schedule_values[i]
        if _always_runs(schedule_value)
            setup, child, child_cursor, child_wiring = _child_setup_exprs(algos, cursor, wiring, i)
            append!(exprs, setup)
            append!(exprs, _child_step_exprs(fieldtype(children, i), child, child_cursor, child_wiring, :($(fieldtype(namespace_types, i))()), lc))
            i += 1
            continue
        end
        # The children from `i` on that have the same schedule: one branch.
        last_in_group = i
        while last_in_group < fieldcount(children) && isequal(schedule_values[last_in_group + 1], schedule_value)
            last_in_group += 1
        end
        group = Any[_child_setup_exprs(algos, cursor, wiring, j) for j in i:last_in_group]
        foreach(g -> append!(exprs, first(g)), group)
        tuple_of(k) = Expr(:tuple, (g[k] for g in group)...)
        namespaces = Expr(:tuple, (:($(fieldtype(namespace_types, j))()) for j in i:last_in_group)...)
        run = :(@inline should_run_schedule($schedule_value, $this_inc, (@inline getpersistent($lc))))
        push!(exprs, :($lc = @inline _conditional_step($run, $(tuple_of(2)), $(tuple_of(3)), $lc, $(tuple_of(4)), $namespaces, process, lifetime)))
        i = last_in_group + 1
    end
    push!(exprs, :(@inline inc!($cursor, $plan)))
    push!(exprs, :($lc = @inline leave_scope($lc, $outer)))
    return exprs
end

function _routine_step_exprs(PlanType::Type, plan, cursor, wiring, lc)
    repeat_values = PlanType.parameters[2]
    namespace_types = PlanType.parameters[3]
    children = fieldtype(PlanType, :funcs)
    algos, outer = gensym(:algos), gensym(:outer)
    exprs = Any[:(local $algos = @inline getalgos($plan)), :(local $outer = $lc), :($lc = @inline enter_scope($lc, $wiring))]
    for i in 1:fieldcount(children)
        ChildType = fieldtype(children, i)
        repeat_value = repeat_values[i]
        namespace_expr = :($(fieldtype(namespace_types, i))())
        setup, child, child_cursor, child_wiring = _child_setup_exprs(algos, cursor, wiring, i)
        append!(exprs, setup)
        if _steps_inline(ChildType)
            append!(exprs, _inline_routine_child_exprs(ChildType, child, child_cursor, child_wiring, namespace_expr, lc, cursor, i, repeat_value))
        else
            # Repeat counts are part of the plan type: a single-repeat child needs no loop.
            substep = repeat_value isa Repeat && repeats(repeat_value) == 1 ? :_subroutine_step_once! : :_subroutine_step!
            push!(exprs, :($lc = @inline $substep($lc, $child, $child_cursor, $plan, $cursor, process, lifetime, $i, $repeat_value, $child_wiring, $namespace_expr)))
        end
    end
    push!(exprs, :($lc = @inline leave_scope($lc, $outer)))
    return exprs
end

"""
The expressions that repeat a nested plan inside a routine, written inline: as `_subroutine_step!`, with the nested
plan's step in place of the `_step!` call. The repeats carry only the persistent fields the nested plan writes, as the
loops do (see src/Context/Carried/Carry.jl), and the runtime context, which has the same type before and after each
repeat (the nested plan removes its own returns when it ends).
"""
function _inline_routine_child_exprs(ChildType::Type, child, child_cursor, child_wiring, namespace_expr, lc, routine_cursor, i, repeat_value)
    resume_point, count, lidx, done = gensym(:resume_point), gensym(:count), gensym(:lidx), gensym(:done)
    start_persistent, carried, runtime = gensym(:start_persistent_context), gensym(:carried), gensym(:runtime_context)
    # One repeat: the nested plan stepped with the carried fields, in its own `LoopContext` variable.
    function repeat_once()
        stepped = gensym(:stepped_lc)
        return Any[:(local $stepped = @inline withcontexts($lc, (@inline with_carried($start_persistent, $carried)), $runtime)),
                   _child_step_exprs(ChildType, child, child_cursor, child_wiring, namespace_expr, stepped)...,
                   :($runtime = @inline getruntime($stepped)),
                   :($carried = @inline next_carried($carried, (@inline getpersistent($stepped)))),
                   :(@inline tick!(process))]
    end
    # The stop condition sees the persistent and the runtime context: it may read declared locals.
    stop_after(idx_expr, next_expr) = quote
        if @inline routine_breakcondition($repeat_value, lifetime, process, (@inline final_context(LoopContext((@inline with_carried($start_persistent, $carried)), $runtime))), $idx_expr)
            if !(@inline _routine_local_breakcondition($repeat_value, process, (@inline final_context(LoopContext((@inline with_carried($start_persistent, $carried)), $runtime))), $idx_expr))
                @inline set_resume_point!($routine_cursor, $i, $next_expr)
            end
            $(Expr(:symbolicgoto, done))
        end
    end
    once = repeat_value isa Repeat && repeats(repeat_value) == 1
    body = Any[:(local $resume_point = @inline get_resume_point($routine_cursor, $i)),
               :(local $start_persistent = @inline getpersistent($lc)),
               :(local $runtime = @inline getruntime($lc)),
               # The fields the nested plan writes (its `_writes`, nested plans inline: not `create_carried`, which asks
               # what the nested plan's `_step!` returns, from inside this `_step!`).
               :(local $carried = @inline _written_values($start_persistent, (@inline _writes($child, $child_cursor, $start_persistent, (@inline runtime_type(typeof($lc))), $child_wiring, $namespace_expr, process, lifetime))))]
    if once
        push!(body, :(if $resume_point <= 1; $(repeat_once()...); $(stop_after(resume_point, :($resume_point + 1))); end))
    else
        # One loop for all repeats, the body written once. The stop condition is checked after the first repeat and
        # before every later one.
        push!(body, :(local $count = @inline routine_repeat_count($repeat_value)))
        # One loop, one stop check per repeat (see `_subroutine_step!`).
        push!(body, :(if $resume_point <= $count
            for $lidx in $resume_point:$count
                if $lidx > $resume_point
                    $(stop_after(lidx, lidx))
                end
                $(repeat_once()...)
            end
            if $resume_point == $count
                $(stop_after(resume_point, :($resume_point + 1)))
            end
        end))
    end
    push!(body, Expr(:symboliclabel, done))
    push!(body, :($lc = @inline withcontexts($lc, (@inline with_carried($start_persistent, $carried)), $runtime)))
    return body
end

"""
Step each scheduled child of a composite plan with explicit loop runtime.

The `process` and `lifetime` values are forwarded so nested loop algorithms can
run without storing those transient values in the context.
"""
Base.@constprop :aggressive @inline @generated function _step!(ca::PlanType, cursor::CursorType, lc::LoopContextType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType <: CompositeAlgorithm, CursorType<:CompositeLoopCursor, LoopContextType <: LoopContext, WiringViewType <: PlanWiringView, NamespaceType <: Namespace, ProcessType <: AbstractProcess, LifetimeType <: Lifetime}
    return Expr(:block, _plan_step_exprs(PlanType, :ca, :cursor, :wiring, :lc)..., :(return lc))
end

"""
    _conditional_step(run, children, cursors, lc, wirings, namespaces, process, lifetime)

The children (tuples: their values, cursors, wiring views, namespaces) stepped in order when `run`, else `lc`
unchanged, with one type either way (`_conditional_loopcontext_type`). When inference cannot tell what the steps
return, the two cases keep their own types.
"""
@inline function _conditional_step(run::Bool, children::ChildrenType, cursors::CursorsType, lc::LoopContextType, wirings::WiringViewsType, namespaces::NamespacesType, process::ProcessType, lifetime::LifetimeType) where {ChildrenType<:Tuple, CursorsType<:Tuple, LoopContextType<:LoopContext, WiringViewsType<:Tuple, NamespacesType<:Tuple, ProcessType, LifetimeType}
    Stepped = Core.Compiler.return_type(_step_children!, Tuple{LoopContextType, ChildrenType, CursorsType, WiringViewsType, NamespacesType, ProcessType, LifetimeType})
    Target = _conditional_loopcontext_type(LoopContextType, Stepped)
    Target === Nothing && return run ? (@inline _step_children!(lc, children, cursors, wirings, namespaces, process, lifetime)) : lc
    run && return @inline _as_conditional((@inline _step_children!(lc, children, cursors, wirings, namespaces, process, lifetime)), Target)
    return @inline _as_conditional(lc, Target)
end

"""`lc` after `_step!` of each child in turn (tuples of the children and their cursors, wiring views and namespaces)."""
@inline @generated function _step_children!(lc::LoopContextType, children::ChildrenType, cursors, wirings, namespaces, process, lifetime) where {LoopContextType<:LoopContext, ChildrenType<:Tuple}
    steps = (:(lc = @inline _step!(getfield(children, $k), getfield(cursors, $k), lc, getfield(wirings, $k), getfield(namespaces, $k), process, lifetime)) for k in 1:fieldcount(ChildrenType))
    return Expr(:block, steps..., :(return lc))
end

"""
The `LoopContext` type both outcomes of a conditional step get, from the type before it (`Before`) and the type the
steps return (`Stepped`): the runtime fields of `Before`, each with the union of its type before and after; the
fields the steps added are left out. `Nothing` when `Stepped` is not one concrete `LoopContext` type.
"""
Base.@assume_effects :foldable function _conditional_loopcontext_type(@nospecialize(Before), @nospecialize(Stepped))
    (Stepped isa DataType && Stepped <: LoopContext && isconcretetype(Stepped)) || return Nothing
    before = fieldtype(runtime_type(Before), :subcontexts)
    after = fieldtype(runtime_type(Stepped), :subcontexts)
    parts = map(fieldnames(before), fieldtypes(before)) do name, S
        SubContext{name, _joined_fields(getdatatype(S), getdatatype(fieldtype(after, name)))}
    end
    runtime = ProcessContext{NamedTuple{fieldnames(before), Tuple{parts...}}, fieldtype(runtime_type(Stepped), :reg)}
    return LoopContext{persistent_type(Stepped), runtime, Stepped.parameters[3]}
end

"""The fields of the named tuple type `old`, each with the union of its type in `old` and in `new` (nested named tuples field by field)."""
function _joined_fields(@nospecialize(old), @nospecialize(new))
    types = map(fieldnames(old), fieldtypes(old)) do name, T
        N = fieldtype(new, name)
        T <: NamedTuple && N <: NamedTuple ? _joined_fields(T, N) : Union{T, N}
    end
    return NamedTuple{fieldnames(old), Tuple{types...}}
end

"""`lc` as a value of type `Target` (see `_conditional_loopcontext_type`): only the fields `Target` has, converted to its field types."""
@inline @generated function _as_conditional(lc::LoopContextType, ::Type{Target}) where {LoopContextType<:LoopContext, Target}
    LoopContextType === Target && return :lc
    target_runtime = runtime_type(Target)
    target_parts = fieldtype(target_runtime, :subcontexts)
    part_exprs = map(fieldnames(target_parts), fieldtypes(target_parts)) do name, S
        :($S($(_conditional_value_expr(getdatatype(S), :(getdata(getfield(get_subcontexts(getruntime(lc)), $(QuoteNode(name)))))))))
    end
    runtime = :($target_runtime(NamedTuple{$(fieldnames(target_parts))}(($(part_exprs...),)), getfield(getruntime(lc), :reg)))
    return :(LoopContext{$(persistent_type(Target)), $target_runtime, $(Target.parameters[3])}(getpersistent(lc), $runtime))
end

"""The value of type `Target` read from `source` (an expression): a named tuple field by field, anything else as it is."""
function _conditional_value_expr(Target::Type, source)
    Target <: NamedTuple || return source
    values = (_conditional_value_expr(T, :(getfield($source, $(QuoteNode(name))))) for (name, T) in zip(fieldnames(Target), fieldtypes(Target)))
    return :($Target(($(values...),)))
end

"""
The runtime context type after a plan node ends, given the type at its end and the type of its wiring view: without
the node's returns (see `leave_scope`).
"""
Base.@assume_effects :foldable _runtime_context_type_after_leaving(@nospecialize(RuntimeContextType), @nospecialize(WiringViewType)) =
    RuntimeContextType <: ProcessContext ? Core.Compiler.return_type(_strip_returns, Tuple{RuntimeContextType, Val{node_resets(_view_node(WiringViewType))}}) : Any
_view_node(::Type{<:PlanWiringView{Root, WiringType}}) where {Root, WiringType} = WiringType

"""
    _children_writes_expr(PlanType, repeat_values)

The body of `_writes` for a plan that steps its children in order (a composite, routine or threaded composite): the
union of its children's writes, each at its own position (cursor, wiring view, namespace), with the runtime context
type passed from child to child as `_step!` passes the runtime context. A child that repeats (a routine child with
more than one repeat) uses the runtime type it settles on. `repeat_values` is `nothing` for a plan whose children run
once per step. Nested plans are written inline, as in `_plan_step_exprs`: a nested `_writes` call would be the same
method with a growing runtime context type, which inference stops following.
"""
function _children_writes_expr(PlanType::Type, repeat_values)
    exprs = Any[:(local writes = Val(())), :(local runtime_context_type = RuntimeContextType)]
    _children_writes_exprs!(exprs, PlanType, repeat_values, :plan, :cursor, :wiring)
    push!(exprs, :(return writes))
    return Expr(:block, exprs...)
end

"""Append to `exprs` the writes of the children of `plan` (type `PlanType`), nested plans inline; see `_children_writes_expr`."""
function _children_writes_exprs!(exprs, PlanType::Type, repeat_values, plan, cursor, wiring)
    child_namespace_tuple_type = PlanType.parameters[3]
    children = fieldtype(PlanType, :funcs)
    algos = gensym(:algos)
    push!(exprs, :(local $algos = @inline getalgos($plan)))
    for i in 1:numalgos(PlanType)
        ChildType = fieldtype(children, i)
        child_namespace = :($(fieldtype(child_namespace_tuple_type, i))())
        setup, child, child_cursor, child_wiring = _child_setup_exprs(algos, cursor, wiring, i)
        append!(exprs, setup)
        repeated = !isnothing(repeat_values) && !(repeat_values[i] isa Repeat && repeats(repeat_values[i]) == 1)
        if _steps_inline(ChildType)
            # The nested plan's writes, inline, with the runtime context type passed through its children; when it
            # ends its returns are removed, so the type afterwards is the one before it, also over repeats. Nothing
            # here asks what a plan's `_step!` returns: that would be the self-call inference stops following.
            nested_repeats = ChildType <: Routine ? ChildType.parameters[2] : nothing
            _children_writes_exprs!(exprs, ChildType, nested_repeats, child, child_cursor, child_wiring)
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_leaving(runtime_context_type, typeof($child_wiring))))
        else
            repeated && push!(exprs, :(runtime_context_type = @inline _runtime_context_type_over_repeats($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $child_namespace, process, lifetime)))
            push!(exprs, :(writes = @inline _union_writes(writes, (@inline _writes($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $child_namespace, process, lifetime)))))
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_node_step($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $child_namespace, process, lifetime)))
        end
    end
    return exprs
end

# The persistent fields a composite or routine writes (see src/Context/Carried/Writes.jl).
@inline @generated _writes(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:CompositeAlgorithm, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _children_writes_expr(PlanType, nothing)
@inline @generated _writes(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:Routine, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _children_writes_expr(PlanType, PlanType.parameters[2])

"""Step one lifetime-scheduled child inside a `Routine`."""
@inline function _subroutine_step!(
    lc::L,
    func::F,
    func_cursor::FS,
    r::R,
    routine_cursor::RS,
    process::P,
    lifetime::LT,
    idx::Int,
    subroutine_lifetime::SL,
    child_step_wiring::W,
    namespace::N,
) where {L<:LoopContext,F,FS<:AbstractLoopCursor,R<:Routine,RS<:Union{DirectRoutineCursor,PausableRoutineCursor},P<:AbstractProcess,LT<:Lifetime,SL<:Lifetime,W,N<:Namespace}
    resume_point = @inline get_resume_point(routine_cursor, idx)
    this_repeat_count = @inline routine_repeat_count(subroutine_lifetime)
    persistent_context = @inline getpersistent(lc)
    runtime_context = @inline getruntime(lc)
    if resume_point <= this_repeat_count
        # The repeats carry only the fields the child writes, as the loops do (see src/Context/Carried/Carry.jl); `context`
        # stays the routine's starting context.
        carried = @inline create_carried(func, func_cursor, lc, child_step_wiring, namespace, process, lifetime)
        # One loop, one stop check per repeat: before every repeat but the first. The check after the first repeat that
        # came before is implied by the one before the second (same context; it holds whenever that one does), so it
        # only runs when the first repeat is also the last.
        for lidx in resume_point:this_repeat_count
            if lidx > resume_point
                # Built fresh for the break checks: carrying `stepped` instead would make the whole context a loop variable.
                current = @inline with_carried(persistent_context, carried)
                seen = @inline final_context(LoopContext(current, runtime_context))   # the stop condition may read declared locals
                if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, seen, lidx)
                    if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, seen, lidx))
                        @inline set_resume_point!(routine_cursor, idx, lidx)
                    end
                    return @inline withcontexts(lc, current, runtime_context)
                end
            end
            stepped_lc = @inline _step!(func, func_cursor, (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context)), child_step_wiring, namespace, process, lifetime)
            runtime_context = @inline getruntime(stepped_lc)
            carried = @inline next_carried(carried, (@inline getpersistent(stepped_lc)))
            @inline tick!(process)
        end
        if resume_point == this_repeat_count
            current = @inline with_carried(persistent_context, carried)
            seen = @inline final_context(LoopContext(current, runtime_context))
            if (@inline routine_breakcondition(subroutine_lifetime, lifetime, process, seen, resume_point)) && !(@inline _routine_local_breakcondition(subroutine_lifetime, process, seen, resume_point))
                @inline set_resume_point!(routine_cursor, idx, resume_point + 1)
            end
        end
        return (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context))
    end
    return lc
end

"""
Step a routine child that repeats once: the first repeat of `_subroutine_step!` without
the loop, so the child's `_step!` is emitted once instead of twice.
"""
@inline function _subroutine_step_once!(
    lc::L,
    func::F,
    func_cursor::FS,
    r::R,
    routine_cursor::RS,
    process::P,
    lifetime::LT,
    idx::Int,
    subroutine_lifetime::SL,
    child_step_wiring::W,
    namespace::N,
) where {L<:LoopContext,F,FS<:AbstractLoopCursor,R<:Routine,RS<:Union{DirectRoutineCursor,PausableRoutineCursor},P<:AbstractProcess,LT<:Lifetime,SL<:Lifetime,W,N<:Namespace}
    resume_point = @inline get_resume_point(routine_cursor, idx)
    if resume_point <= 1
        lc = @inline _step!(func, func_cursor, lc, child_step_wiring, namespace, process, lifetime)
        @inline tick!(process)
        seen = @inline final_context(lc)   # the stop condition may read declared locals
        if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, seen, resume_point)
            if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, seen, resume_point))
                @inline set_resume_point!(routine_cursor, idx, resume_point + 1)
            end
        end
    end
    return lc
end

"""
Step each child routine in sequence with explicit loop runtime.

Each child is run once at its resume point, then repeated until its declared
repeat count is reached or the lifetime stops. Nested plans are written inline (see `_plan_step_exprs`).
"""
Base.@constprop :aggressive @inline @generated function _step!(r::PlanType, cursor::CursorType, lc::LoopContextType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType <: Routine, CursorType<:Union{DirectRoutineCursor,PausableRoutineCursor}, LoopContextType <: LoopContext, WiringViewType <: PlanWiringView, NamespaceType <: Namespace, ProcessType <: AbstractProcess, LifetimeType <: Lifetime}
    return Expr(:block, _plan_step_exprs(PlanType, :r, :cursor, :wiring, :lc)..., :(return lc))
end

"""
Internal single-step entrypoint for tests and manual loop-plan driving.

This builds the minimal process handle needed by routines and interval logic,
then enters the same `_step!` chain used by `run`.
"""
@inline function _step!(la::LA, persistent_context::C) where {LA<:LoopSpec, C<:AbstractContext}
    lifetime = Indefinite()
    process = LoopRunProcess(lifetime)
    plan = @inline getplan(la)
    cursor = @inline loop_cursor(plan, Val(false))
    runtime_context = @inline _empty_context()
    stepped_lc = @inline _step!(plan, cursor, LoopContext(persistent_context, runtime_context), PlanWiringView(getwiring(plan)), Namespace{nothing}(), process, lifetime)
    return @inline getpersistent(stepped_lc)
end

@inline reset!(la::LoopAlgorithm) = la
