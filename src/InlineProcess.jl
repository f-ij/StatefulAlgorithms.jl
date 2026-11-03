export InlineProcess, InlineProcessAlgorithm, isthreaded, isasync, run, reset!
"""
A fully typed process that is meant for inlining into other Functions
Mainly used to compose algorithms in tight loops, plugging into the ProcessLoopAlgorithm system

This doesn't provide the multitasking features of Process, but is faster to restart
"""
mutable struct InlineProcess{TD,ContextType, Lt,Mode} <: AbstractProcess
    const id::UUID
    algo::TD
    context::ContextType
    consumed::Bool
    lifetime::Lt
    # The run's counter, one session for every run (Sessions/InlineSession.jl): what the loop gets instead of the
    # process.
    const session::InlineSession
end
#TODO Improve context semantics
contexttype(::Union{InlineProcess{TD,ContextType}, Type{<:InlineProcess{TD,ContextType}}}) where {TD,ContextType} = ContextType

@inline function _inline_process_mode(threaded)
    if threaded === true || threaded === :threaded
        return :threaded
    elseif threaded === false || threaded === :sync
        return :sync
    elseif threaded === :async
        return :async
    else
        error("Unsupported InlineProcess execution mode `$threaded`. Use `true`, `false`, `:threaded`, or `:async`.")
    end
end

@inline function _inline_process_lifetime(func, repeats, lifetime)
    if !isnothing(repeats)
        isnothing(lifetime) || error("Pass either `repeats` or `lifetime` to `InlineProcess`, not both.")
        return normalize_process_lifetime(func, repeats)
    elseif isnothing(lifetime)
        return normalize_process_lifetime(func, 1)
    else
        return normalize_process_lifetime(func, lifetime)
    end
end

@inline function InlineProcess(func, inputs_overrides...; threaded=false, repeats=nothing, lifetime=nothing, context=nothing)
    lifetime = _inline_process_lifetime(func, repeats, lifetime)
    algo = normalize_process_algo(func)
    lifetime = normalize_process_lifetime(algo, lifetime)
    algo = isnothing(context) ? init(algo, inputs_overrides...; lifetime) : _with_lifecycle(resolve(algo), context, (), ())
    prepared_context = getpersistentcontext(algo)
    mode = _inline_process_mode(threaded)

    p = InlineProcess{typeof(algo), typeof(prepared_context), typeof(lifetime),mode}(uuid1(), algo, prepared_context, false, lifetime, InlineSession())
    return p
end

@inline isthreaded(ip::InlineProcess{TD,ContextType,Lt,Mode}) where {TD,ContextType,Lt,Mode} = Mode == :threaded
@inline isasync(ip::InlineProcess{TD,ContextType,Lt,Mode}) where {TD,ContextType,Lt,Mode} = Mode == :async

# getlidx(ip::InlineProcess) = Int(ip.loopidx)
@inline lifetime(ip::IP) where {IP<:InlineProcess} = ip.lifetime
@inline getcontext(ip::IP) where {IP<:InlineProcess} = ip.context::contexttype(ip)

getalgo(ip::InlineProcess) = ip.algo

@inline context(ip::InlineProcess, c) = (ip.context = c)
@inline context(ip::InlineProcess) = ip.context::contexttype(ip)

@inline function reset!(p::InlineProcess, inputs_overrides...)
    reset_loopidx!(getsession(p))
    initialized = init(getalgo(p), inputs_overrides...; lifetime = lifetime(p))
    p.context = StatefulAlgorithms.context(initialized)
    # TODO: Probably remove consumed flag
    p.consumed = false
    return true
end

"""
Validate the runtime inputs for one `InlineProcess` execution.

`InlineProcess` has a fixed context type after construction. Per-run data is
therefore limited to declared `@input` keywords; structural reinitialization
stays on `reset!`, where the process can rebuild its persistent context.
"""
@inline function _inline_runtime_inputs(algo::A, inputs_overrides::IO, kwargs::K) where {A<:AbstractLoopAlgorithm, IO<:Tuple, K<:NamedTuple}
    isempty(inputs_overrides) || error("InlineProcess run accepts runtime inputs as keywords only. Use reset!(p, specs...) to reinitialize the context.")
    return _validate_runtime_inputs(algo, kwargs)
end

@inline function Base.run(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, threaded=nothing, kwargs...)
    algo = getalgo(p)
    
    run_context = if isnothing(context)
        StatefulAlgorithms.context(p)
    else
        @assert context isa contexttype(p) "Wrong context shape for this process\n Context is of type $(typeof(context)), but expected $(contexttype(p))."
        context
    end

    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    inputlifetime = isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime
    run_lifetime = _inline_process_lifetime(algo, repeats, inputlifetime)

    if (isnothing(threaded) && isthreaded(p)) || threaded === true
        return Threads.@spawn _run_inline!(p, algo, run_context, run_lifetime, runtime_inputs)
    elseif (isnothing(threaded) && isasync(p)) || threaded === :async
        return @async _run_inline!(p, algo, run_context, run_lifetime, runtime_inputs)
    else
        return @inline _run_inline!(p, algo, run_context, run_lifetime, runtime_inputs)
    end
end

@inline function run_nogen(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, threaded=nothing, kwargs...)
    algo = getalgo(p)
    
    run_context = if isnothing(context)
        StatefulAlgorithms.context(p)
    else
        @assert context isa contexttype(p) "Wrong context shape for this process\n Context is of type $(typeof(context)), but expected $(contexttype(p))."
        context
    end

    # loopdispatch = isnothing(repeat) ? lifetime(p) : _inline_process_lifetime(algo, repeat, nothing)
    inputlifetime = isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime
    run_lifetime = _inline_process_lifetime(algo, repeats, inputlifetime)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))

    return @inline _run_inline!(p, algo, run_context, run_lifetime, runtime_inputs)
end

"""One run of `p`: the loop on the process's session (`run_session_loop`), then its context kept on the process."""
@inline function _run_inline!(p::InlineProcess, algo::A, run_context::C, run_lifetime::LT, runtime_inputs::I) where {A, C, LT, I}
    session = getsession(p)
    reset_loopidx!(session)
    persistent_context, returnvalue = run_session_loop(session, algo, run_context, run_lifetime, runtime_inputs)
    p.context = persistent_context
    return returnvalue
end

@inline function init_and_run(p::InlineProcess, inputs_overrides...)
    @inline makecontext!(p, inputs_overrides...)
    return run(p)
end

    
