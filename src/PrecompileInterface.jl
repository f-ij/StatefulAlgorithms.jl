#=
What a process compiles when it is built: `precompile_interface(x)`, one hook that every process type (and the
`ProcessManager`) extends here, in this file, so all of it is in one place. Each method is one block of plain
`precompile` calls for the calls a user makes on that type that should not compile when first made, written however
suits the type (on tasks in parallel when there are several large ones).

A process's methods are typed on the process, whose type has the plan's `UniqueKeyMap` (in its plan's registry), so they
compile for every set of `Unique` handles; built once per set, they would otherwise compile at the first run. The
methods here are untyped (`@nospecializeinfer`) and read fields: typed on the process, the block itself would compile
for every set of handles too.

Not the package's precompile workload (src/Precompile.jl): that runs once, while the package image is written.
=#

"""
    precompile_interface(x) -> nothing

Hook: compiles, when `x` is built, the calls on it a user makes that should not compile when first made. The default
compiles nothing. Called by the process constructors and `ProcessManager`; extended in this file for `Process`,
`InlineProcess` and `ProcessManager`, and a new process type adds its method here too.
"""
precompile_interface(x::X) where {X} = nothing

# A run: `run(p)` and the task's body (`_run_loop_and_store!`, the loop and the run's end), with the types a run without
# inputs on the process's own lifetime gets from `prepare_for_loop` (the plan and context without the map), in parallel.
# `run(p)` gets them from `prepare_for_loop` untyped, so its call into the task's body is dispatched at run time and is
# compiled here by itself. A plan with required `@input`s has no run without inputs: then only `run(p)`. `pause`,
# `close` and a resumed run compile when first used.
Base.@nospecializeinfer function precompile_interface(@nospecialize(p::Process))
    P = typeof(p); C = P.parameters[2]; LT = typeof(getfield(p, :default_lifetime))
    F = typeof(strip_keymap(getfield(p, :algo))); Ctx = typeof(strip_keymap(getfield(p, :state_context)))
    LC = Core.Compiler.return_type(Tuple{typeof(_process_loop_context), F, Ctx, NamedTuple{(), Tuple{}}})
    @sync begin
        Threads.@spawn precompile(run, (P,))
        isconcretetype(LC) && Threads.@spawn precompile(_run_loop_and_store!, (P, typeof(loop), InteractiveSession{C}, F, LC, LT, Resuming{false}))
    end
    return nothing
end

# `run(ip)` (the loop is a call of its own, `run_session_loop`), on this task: a task for one call only adds its own cost.
Base.@nospecializeinfer function precompile_interface(@nospecialize(ip::InlineProcess))
    precompile(run, (typeof(ip),))
    return nothing
end

# The manager's own calls for its manager, slot and job types, in parallel. Its workers are processes, which compile
# theirs when they are built.
Base.@nospecializeinfer function precompile_interface(@nospecialize(manager::ProcessManager))
    isempty(slots(manager)) && return nothing
    M = typeof(manager); Slot = typeof(first(slots(manager))); Job = _slot_job_type(first(slots(manager)))
    @sync begin
        Threads.@spawn precompile(dispatch!, (M, Job))
        Threads.@spawn precompile(poll!, (M,))
        Threads.@spawn precompile(wait, (M,))
        Threads.@spawn precompile(drain!, (M,))
        Threads.@spawn precompile(run!, (M, Vector{Job}))
        Threads.@spawn precompile(_wait_active_slots!, (M,))
        Threads.@spawn precompile(_wait_for_free_slot!, (M,))
        Threads.@spawn precompile(_finish_done_slots!, (M,))
        Threads.@spawn precompile(_finish_slot!, (M, Slot))
        Threads.@spawn precompile(_start_slot!, (M, Slot, Job))
        Threads.@spawn precompile(_run_kwargs, (M, Slot, Job))
        Threads.@spawn precompile(_slot_isdone, (M, Slot))
    end
    return nothing
end
