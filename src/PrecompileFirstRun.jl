#=
What a process compiles when it is built, so its first run compiles nothing: `precompile_first_run!`, one hook that
every process type (and the `ProcessManager`) extends here, in this file.

A process's own methods (`run(p)`, the run's start, the task's body) are typed on the process, whose type has the
plan's `UniqueKeyMap`, so they are compiled for every set of `Unique` handles. The loop is not (its arguments have no
map) and is compiled once per plan. Each method below lists the signatures its first run calls, and hands them to
`precompile_in_parallel` when there are several worth running side by side.

Not the package's precompile workload (src/Precompile.jl): that runs once, while the package image is written, on
the package's own algorithms.
=#

_is_generating_package_output() = ccall(:jl_generating_output, Cint, ()) != 0

"""
    precompile_first_run!(x) -> nothing

Hook: compiles, when `x` is built, what its first run calls, so the first run compiles nothing. The default
compiles nothing. Extended in this file for `Process`, `InlineProcess` and `ProcessManager`; a new process type adds
its method here too. A process's method is untyped (`@nospecializeinfer`) and reads fields, not accessors: typed on the
process, it would itself compile for every set of `Unique` handles (4-8 ms per `InlineProcess` build, measured).
"""
precompile_first_run!(x::X) where {X} = nothing

"""
    precompile_first_run!(p::Process)

`run(p)`, the run's start with the process's own lifetime (the run's session, `create_session`), and the task's body
for a new run (`ProcessTaskBody`: the loop's contexts, the run's end), each on a task of its own
(`precompile_in_parallel`; 49-56 -> 28-33 ms per build on 15 threads). `pause`, `close` and a resumed run compile when
first used (16 ms together, measured).
"""
Base.@nospecializeinfer function precompile_first_run!(@nospecialize(p::Process))
    P = typeof(p); F, C = P.parameters[1], P.parameters[2]
    LT = typeof(getfield(p, :lifetime))
    # `_context(p)`, written out: a call to it from here would compile it for every set of handles.
    runtime_context = getfield(p, :runtime_context)
    Ctx = typeof(isnothing(runtime_context) ? getpersistentcontext(getfield(p, :algo)) : runtime_context)
    # `run(p)` reads the lifetime from a field of abstract type, so its call into `_makeloop!` is dynamic: compiled here
    # with the process's own lifetime (keywords as `makeloop!` passes them).
    precompile_in_parallel(
        Tuple{typeof(run), P},
        Tuple{typeof(Core.kwcall), NamedTuple{(:threaded, :loopfunc), Tuple{Bool, typeof(loop)}}, typeof(_makeloop!), P, NamedTuple{(), Tuple{}}, LT, Ctx},
        Tuple{ProcessTaskBody{P, typeof(loop), InteractiveSession{C, LT}, F, Ctx, LT, NamedTuple{(), Tuple{}}, Resuming{false}}})
    return nothing
end

"""
    precompile_first_run!(ip::InlineProcess)

`run(ip)` (2.8-3.4 ms; the loop is a call of its own, `run_session_loop!`). Not `context(ip)`: `run(ip)` returns the
context, so a first run does not call it, and compiling it costs 2.9 ms per build (it compiles when first called).
"""
Base.@nospecializeinfer function precompile_first_run!(@nospecialize(ip::InlineProcess))
    precompile(run, (typeof(ip),))
    return nothing
end

"""
    precompile_first_run!(manager::ProcessManager)

The manager's own calls for its manager, slot and job types (`dispatch!`, `poll!`, `wait`, `run!`, and the slot
steps they make), in parallel. Its workers are processes, which compile their own when they are built.
"""
function precompile_first_run!(manager::M) where {M<:ProcessManager}
    isempty(slots(manager)) && return nothing
    Slot = typeof(first(slots(manager)))
    Job = _slot_job_type(first(slots(manager)))
    precompile_in_parallel(
        Tuple{typeof(dispatch!), M, Job},
        Tuple{typeof(poll!), M},
        Tuple{typeof(wait), M},
        Tuple{typeof(drain!), M},
        Tuple{typeof(run!), M, Vector{Job}},
        Tuple{typeof(_wait_active_slots!), M},
        Tuple{typeof(_wait_for_free_slot!), M},
        Tuple{typeof(_finish_done_slots!), M},
        Tuple{typeof(_finish_slot!), M, Slot},
        Tuple{typeof(_start_slot!), M, Slot, Job},
        Tuple{typeof(_run_kwargs), M, Slot, Job},
        Tuple{typeof(_slot_isdone), M, Slot})
    return nothing
end

"""
    precompile_in_parallel(signatures::Type...)

Compiles each signature (`Tuple{typeof(f), argtypes...}`) on a task of its own and waits for all before returning.
Untyped, so the tasks' code is the same for every signature and compiles once (spawned from a method typed on the
process, it compiled again for every set of `Unique` handles, 4-17 ms). One after another while the package image is
written (`_is_generating_package_output`).
"""
Base.@nospecializeinfer function precompile_in_parallel(@nospecialize(signatures::Type...))
    if _is_generating_package_output()
        foreach(sig -> precompile(sig::Type), signatures)
        return nothing
    end
    tasks = Task[]
    for sig in signatures
        task = Task(PrecompileJob(sig))
        task.sticky = false
        Threads._spawn_set_thrpool(task, :default)
        push!(tasks, schedule(task))
    end
    foreach(wait, tasks)
    return nothing
end

# A task's body for `precompile_in_parallel`: the signature in a field of abstract type, so the body is one method for
# every signature (a closure over it was compiled for each signature's type, 1.1-1.2 ms).
struct PrecompileJob
    signature::Type
end
(job::PrecompileJob)() = precompile(job.signature)

# The loop precompiled by itself, for a process's loop function (`loop`): not used, as `schedule_loop_precompile!`
# and `wait_loop_precompile!` do nothing; the loop is now entered through `run_session_loop` (TODO.md, "Process files").
@inline function precompile_loop!(loopfunc, p::Process{F, C}, func, context, lt, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {F, C}
    # The loop runs on the session of a run with this lifetime (`create_session`), not on the process.
    precompile_loop!(typeof(loopfunc), InteractiveSession{C, typeof(lt)}, typeof(func), typeof(context), typeof(lt), typeof(inputs), typeof(resume))
    return nothing
end

@inline precompile_loop!(p::Process, func, context, lt) = precompile_loop!(loop, p, func, context, lt)

function _callable_instance(::Type{F}) where {F}
    return isdefined(F, :instance) ? getfield(F, :instance) : nothing
end

function precompile_loop!(
    loopfunc_type::Type,
    session_type::Type,
    func_type::Type,
    context_type::Type,
    lifetime_type::Type,
    inputs_type::Type,
    resume_type::Type,
)
    loopfunc = _callable_instance(loopfunc_type)
    isnothing(loopfunc) && return nothing
    Base.precompile(loopfunc, (session_type, func_type, context_type, lifetime_type, inputs_type, resume_type, NonGenerated))
    return nothing
end

function _schedule_loop_precompile!(
    loopfunc_type::Type,
    session_type::Type,
    func_type::Type,
    context_type::Type,
    lifetime_type::Type,
    inputs_type::Type,
    resume_type::Type,
)
    if _is_generating_package_output()
        precompile_loop!(loopfunc_type, session_type, func_type, context_type, lifetime_type, inputs_type, resume_type)
    else
        Threads.@spawn precompile_loop!(loopfunc_type, session_type, func_type, context_type, lifetime_type, inputs_type, resume_type)
    end
    return nothing
end

function schedule_loop_precompile!(p::Process, lt = lifetime(p); loopfunc = loop)
    # Do not asynchronously precompile user-shaped process loops from the
    # constructor. Immediate `run` calls otherwise compile the same large loop
    # in the foreground while the background precompile is still active.
    return p
end

function wait_loop_precompile!(p::Process, func, context, lt, inputs::NamedTuple, resume::Resuming; loopfunc = loop)
    return nothing
end
