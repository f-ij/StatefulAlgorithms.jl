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

# A run: `run(p)`, the run's start with the process's own lifetime (`_makeloop!`, which makes the run's session), and
# the task's body (`ProcessTaskBody`: the loop's contexts, the run's end), in parallel (49-56 -> 25-28 ms per build on
# 15 threads). `run(p)` reads the context from a field of abstract type, so its call into `_makeloop!` is dynamic and
# is compiled here by itself. `pause`, `close` and a resumed run compile when first used (16 ms together). Each task
# captures `p`, untyped, and takes the types from it: a task over a type (`P = typeof(p)` outside it) is compiled for
# that type, 1.1-1.4 ms for every set of handles.
Base.@nospecializeinfer function precompile_interface(@nospecialize(p::Process))
    @sync begin
        Threads.@spawn precompile(run, (typeof(p),))
        Threads.@spawn precompile(Core.kwcall, (NamedTuple{(:threaded, :loopfunc), Tuple{Bool, typeof(loop)}}, typeof(_makeloop!),
            typeof(p), NamedTuple{(), Tuple{}}, typeof(getfield(p, :lifetime)), typeof(getpersistentcontext(getfield(p, :algo)))))
        Threads.@spawn precompile(Tuple{ProcessTaskBody{typeof(p), typeof(loop),
            InteractiveSession{typeof(p).parameters[2], typeof(getfield(p, :lifetime))}, typeof(getfield(p, :algo)),
            typeof(getpersistentcontext(getfield(p, :algo))), typeof(getfield(p, :lifetime)), NamedTuple{(), Tuple{}}, Resuming{false}}})
    end
    return nothing
end

# `run(ip)` (2.8-3.4 ms; the loop is a call of its own, `run_session_loop!`), on this task: a task for one call only
# adds its own cost. Not `context(ip)`: `run(ip)` returns the context, and compiling it costs 2.9 ms per build.
Base.@nospecializeinfer function precompile_interface(@nospecialize(ip::InlineProcess))
    precompile(run, (typeof(ip),))
    return nothing
end

# The manager's own calls for its manager, slot and job types, in parallel; each task captures `manager`, untyped, as
# for `Process`. Its workers are processes, which compile theirs when they are built.
Base.@nospecializeinfer function precompile_interface(@nospecialize(manager::ProcessManager))
    isempty(slots(manager)) && return nothing
    @sync begin
        for f in (poll!, wait, drain!, _wait_active_slots!, _wait_for_free_slot!, _finish_done_slots!)
            Threads.@spawn precompile(f, (typeof(manager),))
        end
        for f in (_finish_slot!, _slot_isdone)
            Threads.@spawn precompile(f, (typeof(manager), typeof(first(slots(manager)))))
        end
        for f in (_start_slot!, _run_kwargs)
            Threads.@spawn precompile(f, (typeof(manager), typeof(first(slots(manager))), _slot_job_type(first(slots(manager)))))
        end
        Threads.@spawn precompile(dispatch!, (typeof(manager), _slot_job_type(first(slots(manager)))))
        Threads.@spawn precompile(run!, (typeof(manager), Vector{_slot_job_type(first(slots(manager)))}))
    end
    return nothing
end
