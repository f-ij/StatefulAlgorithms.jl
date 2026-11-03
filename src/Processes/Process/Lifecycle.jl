#=
What a user calls on a `Process`: `run`, `wait`, `fetch`, `pause`, `close`, `restart`, `reinit`, `quit`, `quitall`
(TODO.md, "Rename `src/ProcessInteraction.jl`": still mixes in loop internals and dead code).
=#

export start, restart, quit, pause, syncclose, reinit

"""
Resolve the optional lifetime controls for one `Process` run.

`Process` construction may intentionally store an indefinite lifetime. These
per-run controls let callers execute the same prepared process for a finite or
otherwise different lifetime without rebuilding its initialized context.
"""
@inline function _process_run_lifetime(algo::A, run_lifetime::RL, repeats::R, keyword_lifetime::KL) where {A<:AbstractLoopAlgorithm, RL, R, KL}
    if !isnothing(repeats)
        isnothing(run_lifetime) || error("Pass either a positional lifetime or `repeats`, not both.")
        isnothing(keyword_lifetime) || error("Pass either `repeats` or `lifetime`, not both.")
        return normalize_process_lifetime(algo, repeats)
    elseif !isnothing(keyword_lifetime)
        isnothing(run_lifetime) || error("Pass either a positional lifetime or `lifetime`, not both.")
        return normalize_process_lifetime(algo, keyword_lifetime)
    elseif isnothing(run_lifetime)
        return nothing
    else
        return normalize_process_lifetime(algo, run_lifetime)
    end
end

function Base.run(p::Process, run_lifetime = nothing, inputs_and_overrides...; repeats = nothing, lifetime = nothing, kwargs...)
    @assert isidle(p) "Process is already in use"

    if ispaused(p)
        isnothing(run_lifetime) || error("Cannot change lifetime while resuming a paused Process.")
        isnothing(repeats) || error("Cannot change lifetime while resuming a paused Process.")
        isnothing(lifetime) || error("Cannot change lifetime while resuming a paused Process.")
        isempty(inputs_and_overrides) || error("Cannot pass init/override specs while resuming a paused Process.")
        isempty(kwargs) || error("Cannot pass new runtime inputs while resuming a paused Process.")
        return _resume_paused_loop!(p)
    end
    isempty(inputs_and_overrides) || error("Process run accepts runtime inputs as keywords only. Reinitialize the Process context before running to apply init/override specs.")

    lt = _process_run_lifetime(getalgo(p), run_lifetime, repeats, lifetime)
    if !isnothing(lt)
        p.lifetime = lt
    end

    makeloop!(p, (; kwargs...))
end

function Base.run(p::AP, lifetime = nothing, inputs_and_overrides...; kwargs...) where AP <: AbstractProcess
    @assert isidle(p) "Process is already in use"
    makeloop!(p, (; kwargs...))
end

run!(p::Process; kwargs...) = run(p; kwargs...)

"""
Wait for a process to finish
"""
@inline Base.wait(@nospecialize(p::Process)) = if !isnothing(p.task) wait(p.task) else nothing end

"""
Finish a paused run when `close` is called on a paused `Process`.

A paused loop never returns to its end, so this does that work instead: run `cleanup` on the state context and the
runtime context the pause kept (`context(p)`, `p.runtime_context`), combined again into one `LoopContext` as on a
resume; store the final result in `p.lastresult`; clear `p.runtime_context`; and sync the cleaned persistent context
into the state context (`_sync_state_context!`). Returns `p.lastresult`.
"""
function _cleanup_paused_process!(p::Process)
    cleaned = @inline cleanup(getalgo(p), LoopContext(context(p), p.runtime_context))
    p.lastresult = @inline loop_final_result(getalgo(p), (@inline final_context(cleaned)), getruntime(cleaned))
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
        _sync_state_context!(p, context(init(getalgo(p); lifetime = lifetime(p))))

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
Pause, re-init and unpause a process
This is useful mostly for processes that run indefinitely,
where the prepared context is computed from the input context.

This will cause the computed properties to re-compute. 
This may be used also to levarge the dispatch system, if the types of the data change
so that the new loop function is newly compiled
"""
function reinit(p::Process)
    pause(p)
    wait(p)
    # A paused run keeps its runtime context: it resumes with the new state.
    _sync_state_context!(p, context(init(getalgo(p); lifetime = lifetime(p))))
    run(p)
    return true
end

"""
Pause a process, re-run `init` for one registered subcontext, and unpause it.

The target can be a registry symbol or registered algorithm reference. `inputs`
are merged into the target subcontext before `init`, and `overrides` are merged
afterwards.
"""
function reinit(p::Process, target; inputs = (;), overrides = (;))
    pause(p)
    wait(p)
    _sync_state_context!(p, initcontext(context(p), target; inputs, overrides))
    run(p)
    return true
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
Fetch the return value of a process
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

function timedwait(p, timeout = wait_timeout)
    t = time()
    
    while !isdone(p) && time() - t < timeout
    end

    return isdone(p)
end
