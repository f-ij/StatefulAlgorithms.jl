
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

    @atomic p.shouldrun = true
    @atomic p.paused = false

    lt = _process_run_lifetime(getalgo(p), run_lifetime, repeats, lifetime)
    if !isnothing(lt)
        p.lifetime = lt
    end

    makeloop!(p, (; kwargs...))
end

function Base.run(p::AP, lifetime = nothing, inputs_and_overrides...; kwargs...) where AP <: AbstractProcess
    @assert isidle(p) "Process is already in use"
    @atomic p.shouldrun = true
    @atomic p.paused = false
    makeloop!(p, (; kwargs...))
end

run!(p::Process; kwargs...) = run(p; kwargs...)

"""
Wait for a process to finish
"""
@inline Base.wait(@nospecialize(p::Process)) = if !isnothing(p.task) wait(p.task) else nothing end

function _cleanup_paused_process!(p::Process, fetched_result)
    # A paused task already stored its live runtime context when the loop exited.
    # `close` turns that paused lifecycle into a final one, so cleanup must run
    # here because the loop will not re-enter `after_while`.
    cleanup_context = fetched_result isa AbstractContext ? fetched_result : context(p)
    cleanup_runtimecontext = @inline _initial_runtime_context(getruntimeinput(cleanup_context), p, lifetime(p))
    cleanup_state_context = @inline _paused_state_context(cleanup_context)
    cleaned_context, cleaned_runtimecontext = @inline cleanup(getalgo(p), cleanup_state_context, cleanup_runtimecontext)
    cleaned_context = @inline _paused_state_context(cleaned_context)
    final_context = @inline final_visible_context(cleaned_context, cleaned_runtimecontext)
    p.lastresult = @inline _loop_final_result(getalgo(p), final_context, cleaned_runtimecontext)
    commit_context!(p, cleaned_context)
    return p.lastresult
end


"""
Close a process, stopping it from running
"""
function Base.close(p::Process)
    was_paused = ispaused(p)
    @atomic p.paused = false
    @atomic p.shouldrun = false

    fetched_result = nothing
    try
        wait(p)
        if !isnothing(p.task)
            fetched_result = fetch(p)
            p.lastresult = fetched_result
        end

        was_paused && _cleanup_paused_process!(p, fetched_result)
    catch(err)
        println("Process with error closed:")
        Base.showerror(stderr, err)
        p.task = nothing
        commit_context!(p, context(init(getalgo(p); lifetime = lifetime(p))))

    end

    p.task = nothing 

    p.loopidx = 1
    return true
end

function restart(p::Process)
    close(p)
    wait(p)
    @atomic p.paused = false # Force reinit
    run(p)
end

"""
Pause a process, allowing it to be unpaused later
"""
function pause(p::Process)
    @atomic p.paused = true
    @atomic p.shouldrun = false
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
    commit_context!(p, context(init(getalgo(p); lifetime = lifetime(p))))
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
    commit_context!(p, initcontext(context(p), target; inputs, overrides))
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
