#=
One step of a plan: the generated `_step!` of a composite and of a routine, and the generated `_find_writable_fields` (which
persistent fields a plan writes) that the routine repeats need.

Terms used in this file:
- plan: a `CompositeAlgorithm` or a `Routine`. Its children are in `getalgos(plan)`.
- leaf: any child that is not a plan (an algorithm, a `Callable`, a threaded composite, ...). It is stepped by a call
  to its own `_step!`.
- `lc`: the `LoopContext` variable: the persistent context, the runtime context, and the plan node whose scope the step
  is in (see Context/ContextBundles.jl). Every generated line that steps something reads `lc` and assigns it again.
- schedule: when a composite child runs (`Interval{1}` = every step, `@every n` = every n-th step, `RunIf` = on its
  interval when a condition on the context holds).
- repeat: how often a routine child runs in one step of the routine (`Repeat(n)`, `Until(...)`, ...).

1. Nested plans are written inline.
   The generated code of one plan's step is a list of lines. A child that is itself a plan is not stepped by a call to
   its `_step!`; its lines are written into its parent's (`_plan_step_exprs` calls itself while generating). Why: the
   runtime context grows within a step (a return is added at the line that writes it, and removed when its plan node
   ends, see `leave_scope`), so a nested plan gets a larger `LoopContext` type than its parent. Its `_step!` would be the
   same method as its parent's, and Julia's inference stops following a method that calls itself with a growing argument
   type: the call becomes dynamic. Written inline, nothing calls itself, and every line has its exact type.

2. What `_step!` of a composite `ca` emits (`@inline` left out; `child1`, `cursor1`, ... are gensyms):

       local algos = getalgos(ca)
       local inc = inc(cursor)                       # the composite's step count, read by the schedules
       local outer = lc
       lc = enter_scope(lc, wiring)
       # child 1, every step, a leaf:
       local child1 = getfield(algos, 1)
       local cursor1 = child_loop_cursor(cursor, Val(1))
       local wiring1 = child_wiring_view(wiring, Val(1))
       lc = _step!(child1, cursor1, lc, wiring1, Namespace1(), process, lifetime)
       # child 2, every step, a plan: the same three locals, then the lines of 2. or 3. for child 2, here
       # children 3 and 4, on the same schedule (say `@every 2`): the locals of both, then one branch
       lc = _conditional_step(should_run_schedule(schedule3, inc, getpersistent(lc)),
                              (child3, child4), (cursor3, cursor4), lc, (wiring3, wiring4), (Namespace3(), Namespace4()),
                              process, lifetime)
       inc!(cursor, ca)
       lc = leave_scope(lc, outer)
       return lc

   Consecutive children on the same schedule share one branch (an algorithm and the call that captures its return are
   such a pair). The children in a branch are stepped by calls to `_step!`, also when they are plans. After the branch
   `lc` has one type whether it ran or not (`_conditional_step`): the fields it had before, a field the branch assigned
   with another type as the union of both (`y = nothing`, then `y = @every 2 f()`), and nothing the branch added. The
   DSL only lets a scheduled statement assign a name that exists before it, so what a branch adds is internal (an
   algorithm's return, read by its capture in the same branch).

3. What `_step!` of a routine `r` emits:

       local algos = getalgos(r)
       local outer = lc
       lc = enter_scope(lc, wiring)
       # child 1, a leaf: the three locals, then one call that runs all its repeats
       lc = _subroutine_step!(lc, child1, cursor1, r, cursor, process, lifetime, 1, repeat1, wiring1, Namespace1())
       # child 2, a plan: the three locals, then its repeat loop, here (`_inline_routine_child_exprs`)
       local resume_point = get_resume_point(cursor, 2)
       local start_persistent = getpersistent(lc)
       local runtime = getruntime(lc)
       local carried = create_carried(child2, cursor2, lc, wiring2, Namespace2(), process, lifetime)   # the fields child 2 writes
       local count = routine_repeat_count(repeat2)
       for lidx in resume_point:count
           if lifetime_breakcondition(repeat2, <context>, lidx - 1)    # child 2's own stop condition
               @goto done
           end
           local stepped = withcontexts(lc, with_carried(start_persistent, carried), runtime)
           # the lines of 2. or 3. for child 2, on `stepped` instead of `lc`
           runtime = getruntime(stepped)
           carried = next_carried(carried, getpersistent(stepped))
           tick!(process)
           if process_breakcondition(process)                          # pause or close of the process
               set_resume_point!(cursor, 2, lidx + 1)
               @goto done
           end
       end
       @label done
       lc = withcontexts(lc, with_carried(start_persistent, carried), runtime)
       lc = leave_scope(lc, outer)
       return lc

   `<context>` is `final_context(LoopContext(with_carried(start_persistent, carried), runtime))`. A child with
   `Repeat(1)` has no loop: a leaf calls `_subroutine_step_once!`, and for a plan the loop is replaced by
   `if resume_point <= 1; <one repeat>; <the pause check>; end` (no own stop condition).

4. What `_find_writable_fields` of a plan emits (`_children_writes_expr`):

       local writes = Val(())
       local runtime_context_type = RuntimeContextType
       local algos = getalgos(plan)
       # child 1, a leaf: the three locals, then
       writes = _merge_writable_fields(writes, _find_writable_fields(child1, cursor1, persistent_context, runtime_context_type, wiring1, Namespace1(), process, lifetime))
       runtime_context_type = _runtime_context_type_after_node_step(child1, cursor1, persistent_context, runtime_context_type, wiring1, Namespace1(), process, lifetime)
       # child 2, a plan: the three locals, then the lines of 4. for child 2's children, here, then
       runtime_context_type = _runtime_context_type_after_leaving(runtime_context_type, typeof(wiring2))
       return writes
=#

"""
`true` when a child of type `ChildType` is a plan (composite or routine): its lines are written into its parent's
step. `false` for a leaf, which is stepped by a call to its `_step!`. See the file header, 1.
"""
_steps_inline(::Type) = false
_steps_inline(::Type{<:Union{CompositeAlgorithm, Routine}}) = true

"""`true` when a composite child's schedule value is `Interval{1}` (it runs every step, so it needs no branch), else `false`."""
_always_runs(::Interval{1}) = true
_always_runs(::Integer) = false
_always_runs(::Any) = false

"""
The lines (a `Vector` of expressions) that step `plan` once: the file header, 2. for a composite, 3. for a routine.

`PlanType` is the plan's type. `plan`, `cursor` and `wiring` are expressions for the plan, its loop cursor and its
wiring view. `lc` is the name of the `LoopContext` variable the lines read and assign.
"""
_plan_step_exprs(PlanType::Type{<:CompositeAlgorithm}, plan, cursor, wiring, lc) = _composite_step_exprs(PlanType, plan, cursor, wiring, lc)
_plan_step_exprs(PlanType::Type{<:Routine}, plan, cursor, wiring, lc) = _routine_step_exprs(PlanType, plan, cursor, wiring, lc)

"""
The lines that step one child once, assigning `lc`: the child's own lines (`_plan_step_exprs`) when it is a plan,
otherwise the single line `lc = _step!(child, cursor, lc, wiring, namespace, process, lifetime)`.
"""
function _child_step_exprs(ChildType::Type, child, cursor, wiring, namespace_expr, lc)
    _steps_inline(ChildType) && return _plan_step_exprs(ChildType, child, cursor, wiring, lc)
    return Any[:($lc = @inline _step!($child, $cursor, $lc, $wiring, $namespace_expr, process, lifetime))]
end

"""
`(lines, child, child_cursor, child_wiring)`: the three lines that bind child `i` of a plan, its loop cursor and its
wiring view to new local variables, and the names of those variables. `plan_algos` is the variable holding the plan's
children; `cursor` and `wiring` are the plan's.
"""
function _child_setup_exprs(plan_algos, cursor, wiring, i)
    child, child_cursor, child_wiring = gensym(:child), gensym(:cursor), gensym(:wiring)
    setup = Any[:(local $child = @inline getfield($plan_algos, $i)),
                :(local $child_cursor = @inline child_loop_cursor($cursor, Val($i))),
                :(local $child_wiring = @inline child_wiring_view($wiring, Val($i)))]
    return setup, child, child_cursor, child_wiring
end

"""The lines that step composite `plan` once (the file header, 2.); arguments as `_plan_step_exprs`."""
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

"""
The lines that step routine `plan` once (the file header, 3.): each child runs all its repeats before the next child
starts. Arguments as `_plan_step_exprs`.
"""
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
The lines that run all repeats of routine child `i`, a plan, assigning `lc` at the end (the file header, 3., child 2).

They do what `_subroutine_step!` does, with the child's own lines in place of its `_step!` call. Between repeats they
carry only the persistent fields the child writes, as the loops do (see src/Context/Carried/Carry.jl), and the runtime
context. That has the same type before and after each repeat (the child removes its own returns when it ends), except a
local declared without a type that gets its first value in a repeat: from then on it has the written type (Locals.jl,
section 3).
`routine_cursor` is the routine's cursor (it holds the resume points) and `repeat_value` the child's repeat.
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
    # Before a repeat, with `done_expr` repeats done: the child's own stop condition (`Until`, ...) ends the child, as a
    # `while` loop's condition (if it already holds, the child does not run). It may read declared locals, so it sees
    # the persistent and the runtime context.
    finished_before(done_expr) = quote
        if @inline lifetime_breakcondition($repeat_value, (@inline final_context(LoopContext((@inline with_carried($start_persistent, $carried)), $runtime))), $done_expr)
            $(Expr(:symbolicgoto, done))
        end
    end
    # After repeat `idx_expr`: a pause or close of the process stops the child; it resumes at the next repeat.
    paused_after(idx_expr) = quote
        if @inline process_breakcondition(process)
            @inline set_resume_point!($routine_cursor, $i, $idx_expr + 1)
            $(Expr(:symbolicgoto, done))
        end
    end
    once = repeat_value isa Repeat && repeats(repeat_value) == 1
    body = Any[:(local $resume_point = @inline get_resume_point($routine_cursor, $i)),
               :(local $start_persistent = @inline getpersistent($lc)),
               :(local $runtime = @inline getruntime($lc)),
               :(local $carried = @inline create_carried($child, $child_cursor, $lc, $child_wiring, $namespace_expr, process, lifetime))]
    if once
        push!(body, :(if $resume_point <= 1; $(repeat_once()...); $(paused_after(resume_point)); end))   # `Repeat(1)`: no own condition
    else
        # One loop, every repeat the same: the child's own condition, the repeat, the pause check (see `_subroutine_step!`).
        push!(body, :(local $count = @inline routine_repeat_count($repeat_value)))
        push!(body, :(for $lidx in $resume_point:$count
            $(finished_before(:($lidx - 1)))
            $(repeat_once()...)
            $(paused_after(lidx))
        end))
    end
    push!(body, Expr(:symboliclabel, done))
    push!(body, :($lc = @inline withcontexts($lc, (@inline with_carried($start_persistent, $carried)), $runtime)))
    return body
end

"""
Step composite `ca` once and return the `LoopContext` after it: each child whose schedule is due, in order, nested
plans inline (the file header, 2.).

`process` and `lifetime` are passed down to the children so that routines inside can check for a pause or close
without keeping them in the context.
"""
Base.@constprop :aggressive @inline @generated function _step!(ca::PlanType, cursor::CursorType, lc::LoopContextType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType <: CompositeAlgorithm, CursorType<:CompositeLoopCursor, LoopContextType <: LoopContext, WiringViewType <: PlanWiringView, NamespaceType <: Namespace, ProcessType <: AbstractProcess, LifetimeType <: Lifetime}
    return Expr(:block, _plan_step_exprs(PlanType, :ca, :cursor, :wiring, :lc)..., :(return lc))
end

"""
Keep the code after it on its own branch. An empty `asm sideeffect` emits no instructions, but LLVM may not compute
what follows it before the condition is known. Without it, LLVM turns a scheduled block (`@every`, `@interval`) into a
`select`: the block is computed every step and the next step waits for the schedule check. As a jump, the CPU's branch
predictor learns the taken/not-taken pattern, which repeats exactly for a fixed interval, so the block costs only on
the steps it runs. The asm is marked as touching only memory no Julia object lives in (`inaccessiblemem`), so values
held in memory (a process's counters, a cursor) need not be reloaded after it.
"""
@inline _keep_branch() = Base.llvmcall(("""
    define void @entry() #0 {
        call void asm sideeffect "", ""() #1
        ret void
    }
    attributes #0 = { alwaysinline }
    attributes #1 = { nounwind memory(inaccessiblemem: readwrite) }
    """, "entry"), Cvoid, Tuple{})

"""
    _conditional_step(run, children, cursors, lc, wirings, namespaces, process, lifetime)

Return `lc` after `_step!` of each child in order when `run` is `true`, else `lc` unchanged. `children`, `cursors`,
`wirings` and `namespaces` are tuples, one entry per child.

Both results are converted to one type (`_compute_conditional_loopcontext_type`), so the code after the branch has
one type, except a local declared without a type that the steps give their first value: it has the written type when
they ran and its placeholder when not. When inference cannot tell which `LoopContext` type the steps return, no type is
chosen: each result is returned as it is, and the call's return type is their union. The steps run on their own
branch (`_keep_branch`).
"""
@inline function _conditional_step(run::Bool, children::ChildrenType, cursors::CursorsType, lc::LoopContextType, wirings::WiringViewsType, namespaces::NamespacesType, process::ProcessType, lifetime::LifetimeType) where {ChildrenType<:Tuple, CursorsType<:Tuple, LoopContextType<:LoopContext, WiringViewsType<:Tuple, NamespacesType<:Tuple, ProcessType, LifetimeType}
    Stepped = Core.Compiler.return_type(_step_children!, Tuple{LoopContextType, ChildrenType, CursorsType, WiringViewsType, NamespacesType, ProcessType, LifetimeType})
    RanType = _compute_conditional_loopcontext_type(LoopContextType, Stepped, true)
    RanType === Nothing && return run ? (_keep_branch(); @inline _step_children!(lc, children, cursors, wirings, namespaces, process, lifetime)) : lc
    run && (_keep_branch(); return @inline _as_conditional((@inline _step_children!(lc, children, cursors, wirings, namespaces, process, lifetime)), RanType))
    return @inline _as_conditional(lc, _compute_conditional_loopcontext_type(LoopContextType, Stepped, false))
end

"""Return `lc` after `_step!` of each child in turn; the arguments are tuples as in `_conditional_step`."""
@inline @generated function _step_children!(lc::LoopContextType, children::ChildrenType, cursors, wirings, namespaces, process, lifetime) where {LoopContextType<:LoopContext, ChildrenType<:Tuple}
    steps = (:(lc = @inline _step!(getfield(children, $k), getfield(cursors, $k), lc, getfield(wirings, $k), getfield(namespaces, $k), process, lifetime)) for k in 1:fieldcount(ChildrenType))
    return Expr(:block, steps..., :(return lc))
end

"""
Return the `LoopContext` type that `_conditional_step` converts its result to when the steps ran (`ran`) or not, or
`Nothing` when `Stepped` is not one concrete `LoopContext` type.

`Before` is the type before the branch, `Stepped` the type after the steps. The result has the persistent context of
`Stepped` and the runtime fields of `Before`, each with the union of its type in `Before` and in `Stepped`, except a
local declared without a type (`_join_fields`). Fields the steps added are left out.
"""
Base.@assume_effects :foldable function _compute_conditional_loopcontext_type(@nospecialize(Before), @nospecialize(Stepped), ran::Bool)
    (Stepped isa DataType && Stepped <: LoopContext && isconcretetype(Stepped)) || return Nothing
    before = fieldtype(runtime_type(Before), :subcontexts)
    after = fieldtype(runtime_type(Stepped), :subcontexts)
    parts = map(fieldnames(before), fieldtypes(before)) do name, S
        SubContext{name, _join_fields(getdatatype(S), getdatatype(fieldtype(after, name)), ran, name === :_declared_locals)}
    end
    runtime = ProcessContext{NamedTuple{fieldnames(before), Tuple{parts...}}, fieldtype(runtime_type(Stepped), :reg)}
    return LoopContext{persistent_type(Stepped), runtime, Stepped.parameters[3]}
end

"""
Return a named tuple type with the field names of `old`, each field typed as the union of its type in `old` and in
`new`. A field that is a named tuple in both is joined field by field instead. Fields only `new` has are left out.
Among `locals` (the declared locals), one declared without a type (its placeholder `undef` or `nothing`) gets its type
in `new` when the steps `ran`, else keeps the placeholder, so its first value overwrites it instead of making a union
(Locals.jl, section 3); `locals` applies to the top level only, the declared locals themselves.
"""
function _join_fields(@nospecialize(old), @nospecialize(new), ran::Bool, locals::Bool)
    types = map(fieldnames(old), fieldtypes(old)) do name, T
        N = fieldtype(new, name)
        locals && _is_untyped_local(T) && return ran ? N : T
        T <: NamedTuple && N <: NamedTuple ? _join_fields(T, N, ran, false) : Union{T, N}
    end
    return NamedTuple{fieldnames(old), Tuple{types...}}
end

"""
Return `lc` converted to `Target` (from `_compute_conditional_loopcontext_type`): only the runtime fields `Target` has, each
converted to its field type there. Returns `lc` itself when it already has type `Target`.
"""
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

"""
Return an expression that builds a value of type `Target` from the expression `source`: for a named tuple type, a
`Target(...)` call built field by field; for anything else, `source` itself (converted by the field it is stored in).
"""
function _conditional_value_expr(Target::Type, source)
    Target <: NamedTuple || return source
    values = (_conditional_value_expr(T, :(getfield($source, $(QuoteNode(name))))) for (name, T) in zip(fieldnames(Target), fieldtypes(Target)))
    return :($Target(($(values...),)))
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

"""
    _children_writes_expr(PlanType)

Return the body of the generated `_find_writable_fields` for a plan that steps its children in order (a composite, routine or
threaded composite); see the file header, 4. The body returns the union of the persistent fields its children write,
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
        if _steps_inline(ChildType)
            # The nested plan's writes, inline, with the runtime context type passed through its children; when it
            # ends its returns are removed, so the type afterwards is the one before it, also over repeats. Nothing
            # here asks what a plan's `_step!` returns: that would be the self-call inference stops following.
            _children_writes_exprs!(exprs, ChildType, child, child_cursor, child_wiring)
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_leaving(runtime_context_type, typeof($child_wiring))))
        else
            push!(exprs, :(writes = @inline _merge_writable_fields(writes, (@inline _find_writable_fields($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $child_namespace, process, lifetime)))))
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_node_step($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $child_namespace, process, lifetime)))
        end
    end
    return exprs
end

# The persistent fields a composite or routine writes in one step, as a `Val` of names (see src/Context/Carried/Writes.jl).
@inline @generated _find_writable_fields(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:CompositeAlgorithm, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _children_writes_expr(PlanType)
@inline @generated _find_writable_fields(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:Routine, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _children_writes_expr(PlanType)

"""
Run the repeats of routine child `idx`, a leaf, and return `lc` after them (the file header, 3., child 1).

The repeats start at the child's resume point in `routine_cursor` and run until the child's repeat
(`subroutine_lifetime`) is done or its stop condition holds. When the process is paused or closed after a repeat,
the next repeat is stored as the resume point and the loop stops. `lc` is returned unchanged when the resume point
is past the last repeat.
"""
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
        # The repeats carry only the fields the child writes, as the loops do (see src/Context/Carried/Carry.jl);
        # `persistent_context` stays the routine's starting context, only `carried` changes.
        carried = @inline create_carried(func, func_cursor, lc, child_step_wiring, namespace, process, lifetime)
        # Every repeat the same:
        # - before it, the child's own stop condition (`Until`, ...), as a `while` loop's condition: if it already holds,
        #   the child does not run. It gets the number of repeats done.
        # - after it, a pause or close of the process: the child resumes at the next repeat. Every repeat (of any child)
        #   is followed by this check, so a pause is seen between any two repeats, also between two children (repeats
        #   can run for a long time). After, not before: a check before the update made LLVM select between the new and
        #   old values on the `shouldrun` byte, which put that read in every update's dependency chain.
        # The stop condition may read declared locals, so it sees the persistent and the runtime context. Built fresh
        # for each check: carrying `stepped` instead would make the whole context a loop variable.
        for lidx in resume_point:this_repeat_count
            if @inline lifetime_breakcondition(subroutine_lifetime, (@inline final_context(LoopContext((@inline with_carried(persistent_context, carried)), runtime_context))), lidx - 1)
                break
            end
            stepped_lc = @inline _step!(func, func_cursor, (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context)), child_step_wiring, namespace, process, lifetime)
            runtime_context = @inline getruntime(stepped_lc)
            carried = @inline next_carried(carried, (@inline getpersistent(stepped_lc)))
            @inline tick!(process)
            if @inline process_breakcondition(process)
                @inline set_resume_point!(routine_cursor, idx, lidx + 1)
                break
            end
        end
        return (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context))
    end
    return lc
end

"""
Run routine child `idx`, a leaf with `Repeat(1)`, once (unless already run before a pause), and return `lc` after it.

It is `_subroutine_step!` without the loop and without the child's own stop condition; only the pause or close check
after the step stays.
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
    if resume_point <= 1   # `Repeat(1)`: no own stop condition, only a pause or close after the repeat
        lc = @inline _step!(func, func_cursor, lc, child_step_wiring, namespace, process, lifetime)
        @inline tick!(process)
        if @inline process_breakcondition(process)
            @inline set_resume_point!(routine_cursor, idx, resume_point + 1)
        end
    end
    return lc
end

"""
Step routine `r` once and return the `LoopContext` after it: each child in order runs all its repeats, from its
resume point, until its repeat is done, its stop condition holds, or the process is paused or closed. Nested plans are
written inline (the file header, 3.).
"""
Base.@constprop :aggressive @inline @generated function _step!(r::PlanType, cursor::CursorType, lc::LoopContextType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType <: Routine, CursorType<:Union{DirectRoutineCursor,PausableRoutineCursor}, LoopContextType <: LoopContext, WiringViewType <: PlanWiringView, NamespaceType <: Namespace, ProcessType <: AbstractProcess, LifetimeType <: Lifetime}
    return Expr(:block, _plan_step_exprs(PlanType, :r, :cursor, :wiring, :lc)..., :(return lc))
end

"""
Step the plan of `la` once on `persistent_context` and return the persistent context after it. For tests and for
driving a plan by hand.

It builds what `run` would provide (a `LoopRunProcess` with an `Indefinite` lifetime, a fresh cursor, an empty
runtime context) and calls the same `_step!` that `run` calls.
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
