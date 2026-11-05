#=
What a user calls on a `Process`: `run`, `wait`, `fetch`, `pause`, `close`, `restart`, `init!`, `quit`, `quitall`
(TODO.md, "Rename `src/ProcessInteraction.jl`": still mixes in loop internals and dead code).
=#

export start, restart, quit, pause, syncclose, closeprocess, reset!

"""
    run(p::Process; repeats, lifetime, inputs...)

Starts a run of `p` on its own task, from its state context, with the run's inputs; a paused run resumes from what its
pause kept, with the lifetime it started with. A new run's lifetime is `repeats`/`lifetime` when given, otherwise
`getlifetime(p)`; it goes into the session (`getlifetime(getsession(p))`) and the process's own stays as it is.
"""
function Base.run(p::Process, inputs_and_overrides...; repeats = nothing, lifetime = nothing, kwargs...)
    @assert isidle(p) "Process is already in use"
    lt = parse_lifetime(lifetime, repeats)

    if ispaused(p)
        isempty(inputs_and_overrides) || error("Cannot pass init/override specs while resuming a paused Process.")
        isempty(kwargs) || error("Cannot pass new runtime inputs while resuming a paused Process.")
        isnothing(lt) || error("Cannot pass `repeats` or `lifetime` while resuming a paused Process: it keeps the lifetime it started with.")
        return _start_run!(p; resume = true)
    end
    isempty(inputs_and_overrides) || error("Process run accepts runtime inputs as keywords only. Use init!(p, InitArgs(...), ...) before running to apply init/override specs.")

    setlifetime!(getsession(p), something(lt, getlifetime(p)))
    _start_run!(p, (; kwargs...))
end

"""
Wait for a process to finish
"""
@inline Base.wait(@nospecialize(p::Process)) = if !isnothing(p.task) wait(p.task) else nothing end

"""
Finish a paused run when `close` is called on a paused `Process`.

A paused loop never returns to its end, so this does that work instead: run `cleanup` on the state context and the
runtime context the pause kept (`getcontext(p)`, `p.runtime_context`), combined again into one `LoopContext` as on a
resume; store the final result in `p.lastresult`; clear `p.runtime_context`; and sync the cleaned persistent context
into the state context (`_sync_state_context!`). Returns `p.lastresult`. Also ends a `TimedProcess` run, which keeps
the same two contexts between its ticks.
"""
function _cleanup_paused_process!(p::InteractiveProcess)
    cleaned = @inline cleanup(getalgo(p), LoopContext(_getcontext_nokeymap(p), p.runtime_context))
    p.lastresult = with_keymap((@inline loop_final_result(getalgo(p), (@inline final_context(cleaned)), getruntime(cleaned))), getfield(p, :keymap))
    p.runtime_context = nothing
    _sync_state_context!(p, getpersistent(cleaned))
    return p.lastresult
end


"""
Close a process, stopping it from running
"""
function Base.close(p::Process)
    was_paused = ispaused(p)
    session = getsession(p)
    @atomic session.paused = false
    @atomic session.shouldrun = false

    try
        wait(p)
        isnothing(p.task) || (p.lastresult = fetch(p))

        was_paused && _cleanup_paused_process!(p)
    catch(err)
        println("Process with error closed:")
        Base.showerror(stderr, err)
        p.task = nothing
        p.runtime_context = nothing
        _sync_state_context!(p, first(_setup(getalgo(p), getspecs(p)...; lifetime = getlifetime(p))))

    end

    p.task = nothing 

    session = getsession(p)
    reset_loopidx!(session)
    session.loop_cursor = nothing
    return true
end

function restart(p::Process)
    close(p)
    wait(p)
    @atomic getsession(p).paused = false # Force reinit
    run(p)
end

"""
Pause a process, allowing it to be unpaused later
"""
function pause(p::Process)
    session = getsession(p)
    @atomic session.paused = true
    @atomic session.shouldrun = false
    return true
end


"""
Start a process that is not running or unpause a paused process
"""
function start(p::Process; prevent_hanging = false, threaded = true)
    @warn "start is deprecated, use run instead"
    run(p)
end   

"""
Close and remove a process from the process list
"""
function quit(p::Process)
    close(p)
    delete!(processlist, p.id)
    return true
end


# """
# Redefine task without preparing again
# """
# function unpause(p::Process; threaded = true)
#     @atomic p.shouldrun = true
#     if threaded
#         p.task = spawnloop(p, getalgo(p), getcontext(p), runtimelisteners(p))
#     else
#         p.task = @async runtask(p, getalgo(p), getcontext(p), runtimelisteners(p))
#     end
#     return true
# end

"""
    init!(p, InitArgs(...), Override(...)) -> p
    init!(p, Only(A, B), InitArgs(...), Override(...)) -> p

Runs `init` again and makes the result the process's state. Without `Only` every `init` runs, from the process's stored
specs with the new ones merged over them (later ones win), on an empty context. With `Only(A, B)` only A's and B's
`init` run, on the current state; the rest is kept. Either way the process keeps the merged specs, so a later full
`init!(p)` sets up from them. A running process is paused for it and runs on after; a paused one stays paused and
resumes with the new state.
"""
function init!(p::Process, specs::InputInterface...)
    was_running = isrunning(p)
    was_running && (pause(p); wait(p))
    context, stored = _init_process_context(p, specs)
    _sync_state_context!(p, context)
    p.specs = stored
    was_running && run(p)
    return p
end

# """
# Close and restart a process
# """
# function restart(p::Process; context...)
    
#     if !isempty(context)
#         changecontext!(p, context...)
#     end

#     #Acquire spinlock so that process can not be started twice
#     return lock(p.lock) do 
#         close(p)
        
#         if timedwait(p, p.timeout)
#             start(p)
#             return true
#         else
#             println("Task timed out")
#             return false
#         end
#     end    
# end

"""
Fetch the return value of a process; a context comes with the plan's `UniqueKeyMap` back in its registry, put there when
the run ended (`_store_run_contexts!`, `_cleanup_paused_process!`).
"""
@inline Base.fetch(@nospecialize(p::Process)) = if !isnothing(p.task) fetch(p.task) else p.lastresult end

"""
Quit all processes in the process list
Might be useful if user lost a reference to a process
"""
function quitall()
    for p in values(processlist)
        quit(p)
    end
end
export quitall

function timedwait(p::Process, timeout = wait_timeout)
    t = time()
    
    while !isdone(p) && time() - t < timeout
    end

    return isdone(p)
end

# TODO: broken, `getglobals` has no method for a process; check whether it is used and what it should close.
function closeprocess(c::AbstractProcess)
    globals = getglobals(c).process
    @assert haskey(globals, :process) "Process context does not have a :process key, cannot close process"
    proc = globals.process
    close(proc)
end
