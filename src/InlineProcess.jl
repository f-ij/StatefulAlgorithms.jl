export InlineProcess, InlineProcessAlgorithm, isthreaded, isasync, run, reset!
"""
A fully typed process that is meant for inlining into other Functions
Mainly used to compose algorithms in tight loops, plugging into the ProcessLoopAlgorithm system

This doesn't provide the multitasking features of Process, but is faster to restart
"""
mutable struct InlineProcess{TD,ContextType, Lt,Mode,K} <: AbstractProcess
    const id::UUID
    algo::TD            # the plan, without the map (the loop's type)
    consumed::Bool
    lifetime::Lt        # its `Var`s numbered as the plan numbers its handles
    # The plan's `UniqueKeyMap` (zero bytes) or `nothing`: in the type, so what the user does with the process is typed
    # (`context(ip)[handle]`, `run(ip; lifetime)` numbering while compiling). Never passed to the loop.
    const keymap::K
    # The run's counter and the process's context, without the map (the loop's type), one session for every run
    # (Sessions/InlineSession.jl): what the loop gets instead of the process.
    const session::InlineSession{ContextType}
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

"""
    InlineProcess(func, Init(...), Override(...); threaded, repeats, lifetime, context)

Resolves `func` first (untyped) and prepares the plan, its context and the lifetime without the plan's `UniqueKeyMap`
(`strip_keymap`, `number_by_keymap_dynamic`), so a new set of `Unique` handles compiles none of that again. Only the
process itself has the map in its type (`keymap`).
"""
Base.@nospecializeinfer function InlineProcess(@nospecialize(func), @nospecialize(inputs_overrides...); context = nothing, @nospecialize(lifetime = nothing), kwargs...)
    algo = func isa LoopSpec ? func : normalize_process_algo(func)
    algo isa LoopSpec && (algo = resolve(algo))
    keymap = getkeymap(algo)
    # The lifetime is not part of the plan: its `Var`s get the plan's numbers here, while the map is known.
    algo, prepared_context, lifetime, mode = _prepare_inline_process(strip_keymap(algo), inputs_overrides...;
        context = strip_keymap(context), lifetime = number_by_keymap_dynamic(lifetime, keymap), kwargs...)
    ip = _construct_inline_process(algo, prepared_context, lifetime, Val(mode), keymap)
    # `run(ip)` is compiled for every set of `Unique` handles (it is typed on the map): compiled here, so the first run
    # does not wait for it. It is small: the loop is a call of its own (`run_session_loop!`).
    precompile(run, (typeof(ip),))
    return ip
end

@inline function _prepare_inline_process(algo, inputs_overrides...; threaded=false, repeats=nothing, lifetime=nothing, context=nothing)
    lifetime = _inline_process_lifetime(algo, repeats, lifetime)
    lifetime = normalize_process_lifetime(algo, lifetime)
    algo = isnothing(context) ? _init_plan(algo, inputs_overrides...; lifetime) : _with_lifecycle(resolve(algo), context, (), ())
    prepared_context = getpersistentcontext(algo)
    # The lifetime's `Var`s by key (`resolve_var_keys`), once: the loop reads them without the registry.
    lifetime = resolve_var_keys(lifetime, prepared_context)
    return algo, prepared_context, lifetime, _inline_process_mode(threaded)
end

# The only step typed on the map: compiled once per set of `Unique` handles, and small.
_construct_inline_process(algo::TD, context::C, lifetime::Lt, ::Val{mode}, keymap::K) where {TD, C, Lt, mode, K} =
    InlineProcess{TD, C, Lt, mode, K}(uuid1(), algo, false, lifetime, keymap, InlineSession(context))

@inline isthreaded(ip::InlineProcess{TD,ContextType,Lt,Mode}) where {TD,ContextType,Lt,Mode} = Mode == :threaded
@inline isasync(ip::InlineProcess{TD,ContextType,Lt,Mode}) where {TD,ContextType,Lt,Mode} = Mode == :async

@inline lifetime(ip::IP) where {IP<:InlineProcess} = ip.lifetime
getcontext(ip::IP) where {IP<:InlineProcess} = context(ip)

getalgo(ip::InlineProcess) = ip.algo

"""Set the process's context to `c` (a context from `context(ip)` has the map: it is taken out)."""
@inline function context(ip::InlineProcess, c)
    getsession(ip).context = detach_keymap(c)
    return _context(ip)
end
@inline _context(ip::InlineProcess) = getsession(ip).context
"""The process's context with the plan's `UniqueKeyMap` in its registry (`attach_keymap`), typed: `context(ip)[handle]`."""
@inline context(ip::InlineProcess) = attach_keymap(_context(ip), getfield(ip, :keymap))

@inline function reset!(p::InlineProcess, inputs_overrides...)
    reset_loopidx!(getsession(p))
    initialized = _init_plan(getalgo(p), inputs_overrides...; lifetime = lifetime(p))
    context(p, getpersistentcontext(initialized))
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

# A context given to `run(ip)`: the run starts from it, so it becomes the process's context (on its session) first.
@inline _set_inline_run_context!(p::InlineProcess, ::Nothing) = nothing
@inline function _set_inline_run_context!(p::InlineProcess, context)
    context = detach_keymap(context)   # a context from `context(ip)` has the map
    @assert context isa contexttype(p) "Wrong context shape for this process\n Context is of type $(typeof(context)), but expected $(contexttype(p))."
    getsession(p).context = context
    return nothing
end

# A lifetime given to `run(ip)`: numbered as the plan numbers its handles while compiling (`number_by_keymap`), and its
# `Var`s given their keys (`resolve_var_keys`; the key is found while compiling), before the call to the loop. The
# process's own lifetime got its keys when the process was built.
@inline _inline_run_lifetime(p::InlineProcess, algo, repeats, ::Nothing) = _inline_process_lifetime(algo, repeats, lifetime(p))
@inline _inline_run_lifetime(p::InlineProcess, algo, repeats, lt) =
    resolve_var_keys(_inline_process_lifetime(algo, repeats, number_by_keymap(lt, getfield(p, :keymap))), _context(p))

@inline function Base.run(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, threaded=nothing, kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    run_lifetime = _inline_run_lifetime(p, algo, repeats, lifetime)

    if (isnothing(threaded) && isthreaded(p)) || threaded === true
        return Threads.@spawn _run_inline!(p, algo, run_lifetime, runtime_inputs)
    elseif (isnothing(threaded) && isasync(p)) || threaded === :async
        return @async _run_inline!(p, algo, run_lifetime, runtime_inputs)
    else
        return @inline _run_inline!(p, algo, run_lifetime, runtime_inputs)
    end
end

@inline function run_nogen(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, threaded=nothing, kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    run_lifetime = _inline_run_lifetime(p, algo, repeats, lifetime)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    return @inline _run_inline!(p, algo, run_lifetime, runtime_inputs)
end

"""
One run of `p`: the loop on the process's session, which holds the process's context and keeps the context after the
run (`run_session_loop!`, a call whose arguments have no map, so the loop is compiled once for every set of `Unique`
handles).
"""
@inline function _run_inline!(p::InlineProcess, algo::A, run_lifetime::LT, runtime_inputs::I) where {A, LT, I}
    return run_session_loop!(getsession(p), algo, run_lifetime, runtime_inputs)
end

@inline function init_and_run(p::InlineProcess, inputs_overrides...)
    @inline makecontext!(p, inputs_overrides...)
    return run(p)
end

    
