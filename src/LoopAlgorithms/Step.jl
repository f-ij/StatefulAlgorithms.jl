#=
One step of a plan: the generated `_step!` of a `Plan`, the resume of a step that stopped for a pause, and the
generated `_find_writable_fields` (which persistent fields a plan writes) that repeats and loops need.

Terms used in this file:
- plan: a `Plan` (built by `CompositeAlgorithm(...)` or `Routine(...)`). Its children are in `getalgos(plan)`, one
  schedule entry per child in `getschedule(plan)`.
- leaf: any child that is not a plan (an algorithm, a `Callable`, a threaded composite, ...). It is stepped by a call
  to its own `_step!`.
- `lc`: the `LoopContext` variable: the persistent context, the runtime context, and the plan node whose scope the step
  is in (see Context/ContextBundles.jl). Every generated line that steps something reads `lc` and assigns it again.
- interval entry: when a child runs, at most once per step of its plan (`Interval{1}` = every step, `@every n` = every
  n-th step, `RunIf` = on its interval when a condition on the context holds).
- repeat entry: how often a child runs in one step of its plan (`Repeat(n)`, `Until(...)`, ...).
- pause point: after a repeat of a repeat entry, where the process is checked for a pause or close.

1. Nested plans are written inline.
   The generated code of one plan's step is a list of lines. A child that is itself a plan is not stepped by a call to
   its `_step!`; its lines are written into its parent's (`_plan_step_exprs` calls itself while generating). Why: the
   runtime context grows within a step (a return is added at the line that writes it, and removed when its plan node
   ends, see `leave_scope`), so a nested plan gets a larger `LoopContext` type than its parent. Its `_step!` would be the
   same method as its parent's, and Julia's inference stops following a method that calls itself with a growing argument
   type: the call becomes dynamic. Written inline, nothing calls itself, and every line has its exact type.

2. What `_step!` of a plan emits (`@inline` left out; `child1`, `cursor1`, ... are gensyms). Each child gets the lines
   of its schedule entry, in order:

       local outer = lc
       lc = enter_scope(lc, wiring)
       local result
       local algos = getalgos(plan)
       local inc = inc(cursor)                       # the plan's step count, read by the interval entries
       # child 1, interval entry `Interval{1}` (every step), a leaf:
       local child1 = getfield(algos, 1)
       local cursor1 = child_loop_cursor(cursor, Val(1))
       local wiring1 = child_wiring_view(wiring, Val(1))
       lc = _step!(child1, cursor1, lc, wiring1, Namespace1(), process, lifetime)
       # child 2, `Interval{1}`, a plan: the same three locals, then the lines of 2. for child 2, here
       # children 3 and 4, on the same interval entry (say `@every 2`): the locals of both, then one branch
       lc = _conditional_step(should_run_schedule(schedule3, inc, getpersistent(lc)),
                              (child3, child4), (cursor3, cursor4), lc, (wiring3, wiring4), (Namespace3(), Namespace4()),
                              process, lifetime)
       # child 5, a repeat entry: the three locals, then its repeat loop (a `RepeatOnce` entry, a stored `Repeat(1)`,
       # has no loop and no own stop condition: the body once, if `first_repeat <= 1`)
       local start_persistent = getpersistent(lc)
       local runtime = getruntime(lc)
       local carried = create_carried(child5, cursor5, lc, wiring5, Namespace5(), process, lifetime)   # the fields child 5 writes
       local count = routine_repeat_count(repeat5)
       for lidx in 1:count
           if lifetime_breakcondition(repeat5, <context>, lidx - 1)    # child 5's own stop condition
               @goto done5
           end
           local stepped = withcontexts(lc, with_carried(start_persistent, carried), runtime)
           # the child's lines on `stepped` instead of `lc`: one `_step!` call, or the lines of 2. for a plan
           runtime = getruntime(stepped)
           carried = next_carried(carried, getpersistent(stepped))
           tick!(process)
           if process_breakcondition(process)                          # a pause point (3.)
               record_pause!(cursor, 5, lidx + 1, <lc now>)
               lc = <lc now>
               result = leave_scope(lc, outer)
               @goto plan_done
           end
       end
       @label done5
       lc = withcontexts(lc, with_carried(start_persistent, carried), runtime)
       inc!(cursor, plan)
       result = leave_scope(lc, outer)
       @label plan_done
       lc = result

   `<context>` is `final_context(LoopContext(with_carried(start_persistent, carried), runtime))` and `<lc now>` is
   `withcontexts(lc, with_carried(start_persistent, carried), runtime)`.

   Consecutive children on the same interval entry share one branch (an algorithm and the call that captures its return
   are such a pair). The children in a branch are stepped by calls to `_step!`, also when they are plans. After the
   branch `lc` has one type whether it ran or not (`_conditional_step`): the fields it had before, a field the branch
   assigned with another type as the union of both (`y = nothing`, then `y = @every 2 f()`), and nothing the branch
   added. The DSL only lets a scheduled statement assign a name that exists before it, so what a branch adds is internal
   (an algorithm's return, read by its capture in the same branch).

   A repeat entry's repeats carry only the persistent fields the child writes, as the loops do (see
   src/Context/Carried/Carry.jl), and the runtime context. That has the same type before and after each repeat (the
   child removes its own returns when it ends, and the declared locals are typed before the loop, Locals.jl section 3).

3. Pausing in the middle of a step.
   At a pause point that finds the process paused or closed, the step stops: the plan records in its cursor which
   child and which repeat to continue at, and the `LoopContext` there (`record_pause!`), leaves its scope and jumps to
   the end of its step, skipping the rest of the step (and its step count). Every exit leaves the scope where it is,
   so `result` has the type a whole step returns.

   A nested plan is written inline (1.), so its exit does not jump to its own end: it runs the lines its parent gave
   it (`on_exit`), which record the parent's position (in a repeat entry: the repeat the child stopped in, to continue
   it; in an interval entry: the child) and leave the parent too, up to the outermost plan written in this function.
   So a parent knows its child stopped without checking after every child; a normal step has no other check than the
   pause points. A plan stepped by a call (a branch of an interval entry, `_conditional_step`) cannot jump: its parent
   checks its cursor after the branch (`is_paused_in_step`). A run that cannot pause (no `PauseRecord` in the
   cursor) records nothing and only stops.

   The next run of a paused process resumes the step (`resume_step!`, called by the loops): it takes the outermost
   plan's record and continues there with the stored `LoopContext`, which still holds the returns of the children
   before. The children before are not run again. As the stored context's type is only known at run time, resuming
   goes through calls compiled for it (`_resume_from!`, `_resume_after_repeat!`, `_resume_after_child!`): a few
   dynamic calls per resume, none in a normal step.

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
`true` when a child of type `ChildType` is a plan: its lines are written into its parent's step. `false` for a leaf,
which is stepped by a call to its `_step!`. See the file header, 1.
"""
_steps_inline(::Type) = false
_steps_inline(::Type{<:Plan}) = true

"""`true` when an interval entry's type is `Interval{1}` (it runs every step, so it needs no branch), else `false`."""
_always_runs(::Type{<:Interval{1}}) = true
_always_runs(::Type) = false

"""
The expression that gives schedule entry `i` (an interval or a repeat) of `plan`, a plan of type `PlanType`: the entry
itself when its type alone decides it (`Interval`, `Indefinite`), else read from the plan's schedule field.
"""
function _schedule_entry_expr(PlanType::Type, plan, i)
    E = fieldtype(fieldtype(PlanType, 2), i)
    Base.issingletontype(E) && return E.instance
    return :(@inline getfield((@inline getschedule($plan)), $i))
end

"""
The lines (a `Vector` of expressions) that step `plan` once (the file header, 2.).

`PlanType` is the plan's type. `plan`, `cursor` and `wiring` are expressions for the plan, its loop cursor and its
wiring view. `lc` is the name of the `LoopContext` variable the lines read and assign. `on_exit` is what the plan
around it runs when this step stops for a pause, after this plan left its scope (`nothing`: jump to the end of this
step), see `_plan_body_exprs`.
"""
function _plan_step_exprs(PlanType::Type, plan, cursor, wiring, lc, on_exit = nothing)
    outer = gensym(:outer)
    exprs = Any[:(local $outer = $lc), :($lc = @inline enter_scope($lc, $wiring))]
    return append!(exprs, _plan_body_exprs(PlanType, plan, cursor, wiring, lc, outer, 1, 1, on_exit))
end

"""
The lines that run the children of `plan` (type `PlanType`) from child `from` to the last, count the step and leave
the plan's scope back to `outer` (an expression for the `LoopContext` the step started with), assigning `lc`.
`first_repeat` is an expression for the repeat child `from` starts at, when it is a repeat entry (resuming starts
there, see the file header, 3.). The other arguments are as in `_plan_step_exprs`.

When the step stops for a pause, the plan leaves its scope where it is (`_exit_step_exprs`) and runs `on_exit`: the
lines of the plan around it, which is written around these lines (a nested plan is inline, the file header, 1.) and
so knows that its child stopped without checking. Without `on_exit` the lines jump to the end of the step.
"""
function _plan_body_exprs(PlanType::Type, plan, cursor, wiring, lc, outer, from::Int, first_repeat, on_exit = nothing)
    g = (; PlanType, plan, cursor, wiring, lc, outer, on_exit, algos = gensym(:algos), this_inc = gensym(:inc),
           result = gensym(:result), done = gensym(:plan_done))
    exprs = Any[:(local $(g.result)), :(local $(g.algos) = @inline getalgos($plan)), :(local $(g.this_inc) = @inline inc($cursor))]
    schedule_types = fieldtype(PlanType, 2)
    children = fieldtype(PlanType, :funcs)
    i = from
    while i <= fieldcount(children)
        schedule_type = fieldtype(schedule_types, i)
        if is_repeat_entry(schedule_type)
            append!(exprs, _repeat_child_exprs(g, i, i == from ? first_repeat : 1))
            i += 1
        elseif _always_runs(schedule_type)
            append!(exprs, _always_child_exprs(g, i))
            i += 1
        else
            last_in_group = _interval_group_end(PlanType, i)
            append!(exprs, _interval_group_exprs(g, i, last_in_group))
            i = last_in_group + 1
        end
    end
    push!(exprs, :(@inline inc!($cursor, $plan)))
    push!(exprs, :($(g.result) = @inline leave_scope($lc, $outer)))
    push!(exprs, Expr(:symboliclabel, g.done))
    push!(exprs, :($lc = $(g.result)))
    return exprs
end

"""
The last child of the branch that starts at child `i` (an interval entry that is not always due): the children from
`i` on with the same entry. Only an entry its type decides is known to be the same, and a child with a pause point
gets a branch of its own, so a pause in it can be seen right after it.
"""
function _interval_group_end(PlanType::Type, i::Int)
    schedule_types = fieldtype(PlanType, 2)
    children = fieldtype(PlanType, :funcs)
    schedule_type = fieldtype(schedule_types, i)
    groupable(j) = Base.issingletontype(schedule_type) && !has_pause_points(fieldtype(children, j))
    groupable(i) || return i
    last_in_group = i
    while last_in_group < fieldcount(children) && fieldtype(schedule_types, last_in_group + 1) === schedule_type && groupable(last_in_group + 1)
        last_in_group += 1
    end
    return last_in_group
end

"""
The lines that leave the plan's scope from where they are when its step stops for a pause (the file header, 3.), then
run the plan around it's `on_exit`, or jump to the end of the step.
"""
function _exit_step_exprs(g)
    isnothing(g.on_exit) && return Any[:($(g.result) = @inline leave_scope($(g.lc), $(g.outer))), Expr(:symbolicgoto, g.done)]
    return Any[:($(g.lc) = @inline leave_scope($(g.lc), $(g.outer))), g.on_exit...]
end

"""
The lines for child `i`, an interval entry due every step. A nested plan that stops for a pause records child `i`
with the `LoopContext` after it and leaves this step too (its `on_exit`).
"""
function _always_child_exprs(g, i::Int)
    ChildType = fieldtype(fieldtype(g.PlanType, :funcs), i)
    setup, child, child_cursor, child_wiring = _child_setup_exprs(g.algos, g.cursor, g.wiring, i)
    on_exit = Any[:(@inline record_pause!($(g.cursor), $i, 1, $(g.lc))), _exit_step_exprs(g)...]
    return append!(setup, _child_step_exprs(ChildType, child, child_cursor, child_wiring, _child_namespace_expr(g.PlanType, i), g.lc, on_exit))
end

"""
The lines for children `first_child` to `last_child`, which share one interval entry: one branch that steps them all
when the entry is due. The children in a branch are stepped by calls (`_step!`), so a branch of one child with a pause
point is followed by a check whether it stopped.
"""
function _interval_group_exprs(g, first_child::Int, last_child::Int)
    group = Any[_child_setup_exprs(g.algos, g.cursor, g.wiring, j) for j in first_child:last_child]
    exprs = Any[]
    foreach(s -> append!(exprs, first(s)), group)
    tuple_of(k) = Expr(:tuple, (s[k] for s in group)...)
    namespaces = Expr(:tuple, (_child_namespace_expr(g.PlanType, j) for j in first_child:last_child)...)
    run = :(@inline should_run_schedule($(_schedule_entry_expr(g.PlanType, g.plan, first_child)), $(g.this_inc), (@inline getpersistent($(g.lc)))))
    push!(exprs, :($(g.lc) = @inline _conditional_step($run, $(tuple_of(2)), $(tuple_of(3)), $(g.lc), $(tuple_of(4)), $namespaces, process, lifetime)))
    if has_pause_points(fieldtype(fieldtype(g.PlanType, :funcs), first_child))
        push!(exprs, quote
            if @inline is_paused_in_step($(group[1][3]))
                @inline record_pause!($(g.cursor), $first_child, 1, $(g.lc))
                $(_exit_step_exprs(g)...)
            end
        end)
    end
    return exprs
end

"""
The lines that run all repeats of child `i`, a repeat entry, from repeat `first_repeat` (an expression), assigning `lc`
at the end (the file header, 2., child 5): the child's own stop condition before each repeat, the pause point after it.
A nested plan that stops for a pause in a repeat records that repeat, to continue it (its `on_exit`); the pause point
after a finished repeat records the next one.
"""
function _repeat_child_exprs(g, i::Int, first_repeat)
    (; plan, cursor, lc) = g
    ChildType = fieldtype(fieldtype(g.PlanType, :funcs), i)
    repeat_value = _schedule_entry_expr(g.PlanType, plan, i)
    namespace_expr = _child_namespace_expr(g.PlanType, i)
    setup, child, child_cursor, child_wiring = _child_setup_exprs(g.algos, cursor, g.wiring, i)
    count, lidx, child_done = gensym(:count), gensym(:lidx), gensym(:child_done)
    start_persistent, carried, runtime = gensym(:start_persistent_context), gensym(:carried), gensym(:runtime_context)
    stepped = gensym(:stepped_lc)
    # The `LoopContext` between repeats: the starting persistent context with the carried fields, and the runtime context.
    now = :(@inline withcontexts($lc, (@inline with_carried($start_persistent, $carried)), $runtime))
    # After a repeat: take what it wrote into the carried fields and the runtime context, and count it.
    after_repeat = Any[:($runtime = @inline getruntime($stepped)),
                       :($carried = @inline next_carried($carried, (@inline getpersistent($stepped)))),
                       :(@inline tick!(process))]
    stop_at(repeat_expr) = Any[:(@inline record_pause!($cursor, $i, $repeat_expr, $now)), :($lc = $now), _exit_step_exprs(g)...]
    body = Any[setup...,
               :(local $start_persistent = @inline getpersistent($lc)),
               :(local $runtime = @inline getruntime($lc)),
               :(local $carried = @inline create_carried($child, $child_cursor, $lc, $child_wiring, $namespace_expr, process, lifetime))]
    if fieldtype(fieldtype(g.PlanType, 2), i) <: RepeatOnce
        # `RepeatOnce` (a stored `Repeat(1)`): one repeat, unless resuming after it; no loop and no own stop condition.
        push!(body, :(if $first_repeat <= 1
            local $stepped = $now
            $(_child_step_exprs(ChildType, child, child_cursor, child_wiring, namespace_expr, stepped, Any[after_repeat..., stop_at(1)...])...)
            $(after_repeat...)
            if @inline process_breakcondition(process)
                $(stop_at(2)...)
            end
        end))
        push!(body, :($lc = $now))
        return body
    end
    push!(body, :(local $count = @inline routine_repeat_count($repeat_value)))
    # One loop, every repeat the same. Before a repeat, with `lidx - 1` repeats done: the child's own stop condition
    # (`Until`, ...) ends the child, as a `while` loop's condition (if it already holds, the child does not run). It may
    # read declared locals, so it sees the persistent and the runtime context. After the repeat: the pause point. After,
    # not before: a check before the update made LLVM select between the new and old values on the `shouldrun` byte,
    # which put that read in every update's dependency chain.
    push!(body, :(for $lidx in $first_repeat:$count
        if @inline lifetime_breakcondition($repeat_value, (@inline final_context(LoopContext((@inline with_carried($start_persistent, $carried)), $runtime))), $lidx - 1)
            $(Expr(:symbolicgoto, child_done))
        end
        local $stepped = $now
        $(_child_step_exprs(ChildType, child, child_cursor, child_wiring, namespace_expr, stepped, Any[after_repeat..., stop_at(lidx)...])...)
        $(after_repeat...)
        if @inline process_breakcondition(process)
            $(stop_at(:($lidx + 1))...)
        end
    end))
    push!(body, Expr(:symboliclabel, child_done))
    push!(body, :($lc = $now))
    return body
end

"""The expression for the `Namespace` of child `i` of a plan of type `PlanType`."""
_child_namespace_expr(PlanType::Type, i::Int) = :($(fieldtype(PlanType.parameters[3], i))())

"""
The lines that step one child once, assigning `lc`: the child's own lines (`_plan_step_exprs`, with `on_exit` for a
pause in it) when it is a plan, otherwise the single line `lc = _step!(child, cursor, lc, wiring, namespace, process,
lifetime)`.
"""
function _child_step_exprs(ChildType::Type, child, cursor, wiring, namespace_expr, lc, on_exit = nothing)
    _steps_inline(ChildType) && return _plan_step_exprs(ChildType, child, cursor, wiring, lc, on_exit)
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

"""
Step `plan` once and return the `LoopContext` after it: each child as its schedule entry says, in order, nested plans
inline (the file header, 2.).

`process` and `lifetime` are passed down to the children so that repeats inside can check for a pause or close
without keeping them in the context.
"""
Base.@constprop :aggressive @inline @generated function _step!(plan::PlanType, cursor::CursorType, lc::LoopContextType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType <: Plan, CursorType<:PlanCursor, LoopContextType <: LoopContext, WiringViewType <: PlanWiringView, NamespaceType <: Namespace, ProcessType <: AbstractProcess, LifetimeType <: Lifetime}
    return Expr(:block, _plan_step_exprs(PlanType, :plan, :cursor, :wiring, :lc)..., :(return lc))
end

###############################################################################
# Resuming (the file header, 3.)
###############################################################################

"""
    resume_step!(plan, cursor, outer, wiring, namespace, process, lifetime)

Finish the step of `plan` that stopped for a pause (`is_paused_in_step(cursor)`), and return the `LoopContext` after
it, as `_step!` would. `outer` is the `LoopContext` the step is resumed in: its persistent context is the current one,
the runtime context and scope at the stopping point come from the cursor's record, which is cleared.

The record's `LoopContext` type is only known at run time, so this call and the ones it makes are compiled for it.
"""
function resume_step!(plan::PlanType, cursor::CursorType, outer::LoopContextType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:Plan, CursorType<:PlanCursor, LoopContextType<:LoopContext, WiringViewType<:PlanWiringView, NamespaceType<:Namespace, ProcessType<:AbstractProcess, LifetimeType<:Lifetime}
    child, repeat, stored = take_pause!(cursor)
    lc = withcontexts(stored, getpersistent(outer), getruntime(stored))
    return _resume_from!(plan, cursor, lc, outer, wiring, namespace, process, lifetime, Val(child), repeat)
end

"""
Run the rest of a step of `plan` from child `I` (repeat `repeat` when it is a repeat entry) on `lc`, then count the
step and leave the scope back to `outer`; return the `LoopContext` after it. When child `I` is a plan whose own step
stopped for a pause, that step is resumed first (`resume_step!`); `lc` is then the plan's `LoopContext` at that
point, the one the child's step runs in.
"""
@generated function _resume_from!(plan::PlanType, cursor::CursorType, lc::LoopContextType, outer::OuterType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType, ::Val{I}, repeat::Int) where {PlanType<:Plan, CursorType<:PlanCursor, LoopContextType<:LoopContext, OuterType<:LoopContext, WiringViewType<:PlanWiringView, NamespaceType<:Namespace, ProcessType<:AbstractProcess, LifetimeType<:Lifetime, I}
    exprs = Any[]
    if I <= numalgos(PlanType) && has_pause_points(fieldtype(fieldtype(PlanType, :funcs), I))
        algos = gensym(:algos)
        setup, child, child_cursor, child_wiring = _child_setup_exprs(algos, :cursor, :wiring, I)
        after = is_repeat_entry(fieldtype(fieldtype(PlanType, 2), I)) ? :_resume_after_repeat! : :_resume_after_child!
        push!(exprs, :(local $algos = getalgos(plan)), setup...)
        push!(exprs, quote
            if is_paused_in_step($child_cursor)
                local stepped = resume_step!($child, $child_cursor, lc, $child_wiring, $(_child_namespace_expr(PlanType, I)), process, lifetime)
                return $after(plan, cursor, lc, stepped, outer, wiring, namespace, process, lifetime, Val(I), repeat)
            end
        end)
    end
    append!(exprs, _plan_body_exprs(PlanType, :plan, :cursor, :wiring, :lc, :outer, I, :repeat))
    return Expr(:block, exprs..., :(return lc))
end

"""
After child `I` (a repeat entry) whose step in repeat `repeat` was resumed (`stepped`, the `LoopContext` after it;
`before`, the plan's one before it): leave again when it stopped again, else the pause point of that repeat, then the
rest of the step (`_resume_from!`). The repeat was counted (`tick!`) when it stopped.
"""
function _resume_after_repeat!(plan::PlanType, cursor::CursorType, before::BeforeType, stepped::SteppedType, outer::OuterType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType, ::Val{I}, repeat::Int) where {PlanType<:Plan, CursorType<:PlanCursor, BeforeType<:LoopContext, SteppedType<:LoopContext, OuterType<:LoopContext, WiringViewType<:PlanWiringView, NamespaceType<:Namespace, ProcessType<:AbstractProcess, LifetimeType<:Lifetime, I}
    lc = withcontexts(before, getpersistent(stepped), getruntime(stepped))
    if is_paused_in_step(child_loop_cursor(cursor, Val(I)))
        record_pause!(cursor, I, repeat, lc)
        return leave_scope(lc, outer)
    elseif process_breakcondition(process)
        record_pause!(cursor, I, repeat + 1, lc)
        return leave_scope(lc, outer)
    end
    return _resume_from!(plan, cursor, lc, outer, wiring, namespace, process, lifetime, Val(I), repeat + 1)
end

"""
After child `I` (an interval entry) whose step was resumed (`after`, the `LoopContext` after it): leave again when it
stopped again, else the rest of the step from child `I + 1` (`_resume_from!`).
"""
function _resume_after_child!(plan::PlanType, cursor::CursorType, before::BeforeType, after::AfterType, outer::OuterType, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType, ::Val{I}, repeat::Int) where {PlanType<:Plan, CursorType<:PlanCursor, BeforeType<:LoopContext, AfterType<:LoopContext, OuterType<:LoopContext, WiringViewType<:PlanWiringView, NamespaceType<:Namespace, ProcessType<:AbstractProcess, LifetimeType<:Lifetime, I}
    if is_paused_in_step(child_loop_cursor(cursor, Val(I)))
        record_pause!(cursor, I, 1, after)
        return leave_scope(after, outer)
    end
    return _resume_from!(plan, cursor, after, outer, wiring, namespace, process, lifetime, Val(I + 1), 1)
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
one type. When inference cannot tell which `LoopContext` type the steps return, no type is
chosen: each result is returned as it is, and the call's return type is their union. The steps run on their own
branch (`_keep_branch`).
"""
@inline function _conditional_step(run::Bool, children::ChildrenType, cursors::CursorsType, lc::LoopContextType, wirings::WiringViewsType, namespaces::NamespacesType, process::ProcessType, lifetime::LifetimeType) where {ChildrenType<:Tuple, CursorsType<:Tuple, LoopContextType<:LoopContext, WiringViewsType<:Tuple, NamespacesType<:Tuple, ProcessType, LifetimeType}
    Stepped = Core.Compiler.return_type(_step_children!, Tuple{LoopContextType, ChildrenType, CursorsType, WiringViewsType, NamespacesType, ProcessType, LifetimeType})
    Joined = _compute_conditional_loopcontext_type(LoopContextType, Stepped)
    Joined === Nothing && return run ? (_keep_branch(); @inline _step_children!(lc, children, cursors, wirings, namespaces, process, lifetime)) : lc
    run && (_keep_branch(); return @inline _as_conditional((@inline _step_children!(lc, children, cursors, wirings, namespaces, process, lifetime)), Joined))
    return @inline _as_conditional(lc, Joined)
end

"""Return `lc` after `_step!` of each child in turn; the arguments are tuples as in `_conditional_step`."""
@inline @generated function _step_children!(lc::LoopContextType, children::ChildrenType, cursors, wirings, namespaces, process, lifetime) where {LoopContextType<:LoopContext, ChildrenType<:Tuple}
    steps = (:(lc = @inline _step!(getfield(children, $k), getfield(cursors, $k), lc, getfield(wirings, $k), getfield(namespaces, $k), process, lifetime)) for k in 1:fieldcount(ChildrenType))
    return Expr(:block, steps..., :(return lc))
end

"""
Return the `LoopContext` type that `_conditional_step` converts its result to, whether the steps ran or not, or
`Nothing` when `Stepped` is not one concrete `LoopContext` type.

`Before` is the type before the branch, `Stepped` the type after the steps. The result has the persistent context of
`Stepped` and the runtime fields of `Before`, each with the union of its type in `Before` and in `Stepped`
(`_join_fields`). Fields the steps added are left out.
"""
Base.@assume_effects :foldable function _compute_conditional_loopcontext_type(@nospecialize(Before), @nospecialize(Stepped))
    (Stepped isa DataType && Stepped <: LoopContext && isconcretetype(Stepped)) || return Nothing
    before = fieldtype(runtime_type(Before), :subcontexts)
    after = fieldtype(runtime_type(Stepped), :subcontexts)
    parts = map(fieldnames(before), fieldtypes(before)) do name, S
        SubContext{name, _join_fields(getdatatype(S), getdatatype(fieldtype(after, name)))}
    end
    runtime = ProcessContext{NamedTuple{fieldnames(before), Tuple{parts...}}, fieldtype(runtime_type(Stepped), :reg)}
    return LoopContext{persistent_type(Stepped), runtime, Stepped.parameters[3]}
end

"""
Return a named tuple type with the field names of `old`, each field typed as the union of its type in `old` and in
`new`. A field that is a named tuple in both is joined field by field instead. Fields only `new` has are left out.
"""
function _join_fields(@nospecialize(old), @nospecialize(new))
    types = map(fieldnames(old), fieldtypes(old)) do name, T
        N = fieldtype(new, name)
        T <: NamedTuple && N <: NamedTuple ? _join_fields(T, N) : Union{T, N}
    end
    return NamedTuple{fieldnames(old), Tuple{types...}}
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

Return the body of the generated `_find_writable_fields` for a plan that steps its children in order (a `Plan` or a
threaded composite); see the file header, 4. The body returns the union of the persistent fields its children write,
each child asked at its own cursor, wiring view and namespace.

The runtime context type is passed from child to child as `_step!` passes the runtime context. A child that repeats is
asked once, with the type before its first repeat: a step removes what it adds and the declared locals are typed before
the loop (Locals.jl section 3), so the type is the same in every repeat. Nested plans are written inline, for the
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

# The persistent fields a plan writes in one step, as a `Val` of names (see src/Context/Carried/Writes.jl).
@inline @generated _find_writable_fields(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:Plan, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _children_writes_expr(PlanType)

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
