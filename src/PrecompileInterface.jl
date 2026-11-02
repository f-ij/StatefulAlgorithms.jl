#=
What a process compiles when it is built: `precompile_interface(x)`, one hook that every process type (and the
`ProcessManager`) extends here, in this file. Each method is a block of `precompile` calls for the interface a user
touches that we want compiled before the first call, written however suits that type (in parallel on tasks when
there are several large ones).

A process's methods are typed on the process, whose type has the plan's `UniqueKeyMap`, so they compile for every set
of `Unique` handles. The methods here are untyped (`@nospecializeinfer`) and read fields, not accessors: typed on the
process, the block itself would compile for every set of handles too.

Not the package's precompile workload (src/Precompile.jl): that runs once, while the package image is written.
=#

"""
    precompile_interface(x) -> nothing

Hook: compiles, when `x` is built, the calls on it a user makes that should not compile when first made. The default
compiles nothing. Extended in this file for `Process`, `InlineProcess` and `ProcessManager`; a new process type adds
its method here too.
"""
precompile_interface(x::X) where {X} = nothing

# A run: `run(p)`, the run's `LoopContext` (its constructor, compiled once as it is not specialized on the context, and
# the bundle it makes from the context without the map), the run's start with the process's own lifetime
# (`_makeloop!`, which makes the run's session) and the task's body (`ProcessTaskBody`: the loop, the run's end), in
# parallel (49-56 -> 25-28 ms per build on 15 threads). `run(p)` reads the lifetime and the context from fields of
# abstract type, so its calls into `prepare_loop` (the session, `LoopContext`) and `_makeloop!` are dispatched at run
# time and compiled here by themselves. `pause`, `close` and a resumed run compile when first used (16 ms together).
Base.@nospecializeinfer function precompile_interface(@nospecialize(p::Process))
    # The loop's plan and context have no map (`_makeloop!`): their types as a run hands them over.
    loop_algo = strip_keymap(getfield(p, :algo))
    P = typeof(p); F = typeof(loop_algo); C = P.parameters[2]; LT = typeof(getfield(p, :lifetime))
    # The `LoopContext` type of a run without inputs, inferred from the context without the map (what the constructor
    # makes from the process's context). A plan with required `@input`s cannot start without them (`Union{}`): its runs
    # have other types, so only `run` is compiled here.
    LC = Core.Compiler.return_type(LoopContext, Tuple{F, typeof(getpersistentcontext(loop_algo)), NamedTuple{(), Tuple{}}, Resuming{false}})
    @sync begin
        Threads.@spawn precompile(run, (P,))
        if LC !== Union{}
            Threads.@spawn precompile(LoopContext, (F, ProcessContext, NamedTuple{(), Tuple{}}, Resuming{false}))
            Threads.@spawn precompile(LoopContext, (persistent_type(LC), runtime_type(LC)))
            Threads.@spawn precompile(create_session, (P, LT))
            Threads.@spawn precompile(Core.kwcall, (NamedTuple{(:threaded, :loopfunc), Tuple{Bool, typeof(loop)}}, typeof(_makeloop!), P, InteractiveSession{C, LT}, F, LC, LT))
            Threads.@spawn precompile(Tuple{ProcessTaskBody{P, typeof(loop), InteractiveSession{C, LT}, F, LC, LT, Resuming{false}}})
        end
    end
    return nothing
end

# `run(ip)` (2.8-3.4 ms; the loop is a call of its own, `run_session_loop`), on this task: a task for one call only
# adds its own cost. Not `context(ip)`: `run(ip)` returns the context, and compiling it costs 2.9 ms per build.
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
