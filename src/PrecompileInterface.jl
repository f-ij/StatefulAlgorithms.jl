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
# the task's body (`ProcessTaskBody`: the loop's contexts, the run's end), in parallel (49-56 -> 28-33 ms per build on
# 15 threads). `run(p)` reads the lifetime from a field of abstract type, so its call into `_makeloop!` is dynamic and
# is compiled here by itself. `pause`, `close` and a resumed run compile when first used (16 ms together).
Base.@nospecializeinfer function precompile_interface(@nospecialize(p::Process))
    P = typeof(p); F, C = P.parameters[1], P.parameters[2]
    LT = typeof(getfield(p, :lifetime))
    runtime_context = getfield(p, :runtime_context)   # `_context(p)`, written out
    Ctx = typeof(isnothing(runtime_context) ? getpersistentcontext(getfield(p, :algo)) : runtime_context)
    signatures = Any[
        Tuple{typeof(run), P},
        Tuple{typeof(Core.kwcall), NamedTuple{(:threaded, :loopfunc), Tuple{Bool, typeof(loop)}}, typeof(_makeloop!), P, NamedTuple{(), Tuple{}}, LT, Ctx},
        Tuple{ProcessTaskBody{P, typeof(loop), InteractiveSession{C, LT}, F, Ctx, LT, NamedTuple{(), Tuple{}}, Resuming{false}}}]
    # By index: a task's closure over a type is compiled for that type (1.1-1.4 ms each, for every set of handles).
    @sync for i in eachindex(signatures)
        Threads.@spawn precompile(signatures[i])
    end
    return nothing
end

# `run(ip)` (2.8-3.4 ms; the loop is a call of its own, `run_session_loop!`), on this task: a task for one call only
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
    signatures = Any[Tuple{typeof(dispatch!), M, Job}, Tuple{typeof(poll!), M}, Tuple{typeof(wait), M}, Tuple{typeof(drain!), M},
        Tuple{typeof(run!), M, Vector{Job}}, Tuple{typeof(_wait_active_slots!), M}, Tuple{typeof(_wait_for_free_slot!), M},
        Tuple{typeof(_finish_done_slots!), M}, Tuple{typeof(_finish_slot!), M, Slot}, Tuple{typeof(_start_slot!), M, Slot, Job},
        Tuple{typeof(_run_kwargs), M, Slot, Job}, Tuple{typeof(_slot_isdone), M, Slot}]
    @sync for i in eachindex(signatures)   # by index, as for `Process`
        Threads.@spawn precompile(signatures[i])
    end
    return nothing
end
