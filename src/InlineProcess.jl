export InlineProcess, InlineProcessAlgorithm, isthreaded, isasync, run, reset!
"""
A fully typed process that is meant for inlining into other Functions
Mainly used to compose algorithms in tight loops, plugging into the ProcessLoopAlgorithm system

This doesn't provide the multitasking features of Process, but is faster to restart
"""
mutable struct InlineProcess{TD,ContextType, Lt,Mode,A} <: AbstractProcess
    const id::UUID
    # The plan, its registry with the plan's `UniqueKeyMap`: the only place the process has the map, so its type has it
    # (`context(ip)[handle]`, `run(ip; lifetime)` numbering while compiling).
    const algo::TD
    consumed::Bool
    lifetime::Lt        # its `Var`s numbered as the plan numbers its handles
    # The plan and the process's context without the map, as the loop takes them (its arguments, `run_session_loop`);
    # the loop gives the new context back and `run(ip)` stores it here.
    const loop_algo::A
    context::ContextType
    # The run's counter, one session for every run (Sessions/InlineSession.jl): what the loop gets instead of the process.
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

"""
    InlineProcess(func, Init(...), Override(...); threaded, repeats, lifetime, context)

Resolves `func` first (untyped) and prepares the plan, its context and the lifetime without the plan's `UniqueKeyMap`
(`strip_keymap`, `number_by_keymap_dynamic`), so a new set of `Unique` handles compiles none of that again. The process
keeps the plan and context so for the loop (`loop_algo`, `context`), and the plan with its registry with the map (`algo`).
"""
Base.@nospecializeinfer InlineProcess(@nospecialize(func), @nospecialize(inputs_overrides...)) =
    _build_inline_process(func, inputs_overrides, nothing, nothing, (;))
# The keyword call, by hand: Julia's own specializes on the keywords' `NamedTuple`, whose type has the handles' uuids
# (a lifetime's `Var`), so it compiled once for every new set of handles (2.5 ms each).
Base.@nospecializeinfer function Core.kwcall(@nospecialize(kw::NamedTuple), ::Type{InlineProcess}, @nospecialize(func), @nospecialize(inputs_overrides...))
    rest = Base.structdiff(kw, NamedTuple{(:context, :lifetime)})
    return _build_inline_process(func, inputs_overrides, get(kw, :context, nothing), get(kw, :lifetime, nothing), rest)
end
Base.@nospecializeinfer function _build_inline_process(@nospecialize(func), @nospecialize(inputs_overrides::Tuple), @nospecialize(context), @nospecialize(lifetime), @nospecialize(kwargs::NamedTuple))
    algo = func isa LoopSpec ? func : normalize_process_algo(func)
    algo isa LoopSpec && (algo = resolve(algo))
    keymap = getkeymap(algo)
    # The lifetime is not part of the plan: its `Var`s get the plan's numbers here, while the map is known.
    algo, prepared_context, lifetime, mode = _prepare_inline_process(strip_keymap(algo), inputs_overrides...;
        context = strip_keymap(context), lifetime = number_by_keymap_dynamic(lifetime, keymap), kwargs...)
    ip = _construct_inline_process(with_keymap(algo, keymap), algo, prepared_context, lifetime, Val(mode))
    # `run(ip)` is typed on the map, so compiled for every set of `Unique` handles: compiled here, so the first run does
    # not wait for it (src/PrecompileInterface.jl).
    precompile_interface(ip)
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

# The only step typed on the map (in `algo`'s registry): compiled once per set of `Unique` handles, and small.
# `loop_algo` and `context` are the plan and its context without the map, the loop's arguments.
function _construct_inline_process(algo::TD, loop_algo::A, context::C, lifetime::Lt, ::Val{mode}) where {TD, A, C, Lt, mode}
    return InlineProcess{TD, C, Lt, mode, A}(uuid1(), algo, false, lifetime, loop_algo, context, InlineSession())
end

@inline isthreaded(ip::InlineProcess{TD,ContextType,Lt,Mode}) where {TD,ContextType,Lt,Mode} = Mode == :threaded
@inline isasync(ip::InlineProcess{TD,ContextType,Lt,Mode}) where {TD,ContextType,Lt,Mode} = Mode == :async

@inline lifetime(ip::IP) where {IP<:InlineProcess} = ip.lifetime
getcontext(ip::IP) where {IP<:InlineProcess} = context(ip)

getalgo(ip::InlineProcess) = ip.algo

"""Set the process's context to `c` (a context from `context(ip)` has the map: it is taken out, `set_loop_context!`)."""
@inline function context(ip::InlineProcess, c)
    set_loop_context!(ip, c)
    return context(ip)
end
"""The process's context as the loop takes it: without the map."""
@inline _context(ip::InlineProcess) = getfield(ip, :context)
"""The process's context with the plan's registry, which has the plan's `UniqueKeyMap` (`with_plan_registry`), typed: `context(ip)[handle]`."""
@inline context(ip::InlineProcess) = with_plan_registry(ip, _context(ip))

"""
Makes `c` the process's context from now on, without the plan's `UniqueKeyMap`, as the loop takes it
(`strip_keymap_typed`; a context from `context(ip)` has the map).
"""
@inline function set_loop_context!(ip::InlineProcess, c)
    ip.context = strip_keymap_typed(c)
    return nothing
end

"""
    with_plan_registry(ip, x) -> x with the map

A context of `ip` from the loop (`x`, without the map) with the registry of `ip`'s plan, which has the plan's
`UniqueKeyMap`: its `Ref` is the plan's context's, so this is typed and makes no registry. A value that is not a
context as it is.
"""
@inline function with_plan_registry(ip::InlineProcess, c::ProcessContext{D}) where {D}
    ref = getfield(getpersistentcontext(getalgo(ip)), :reg)
    return ProcessContext{D, typeof(ref)}(getfield(c, :subcontexts), ref)
end
@inline with_plan_registry(ip::InlineProcess, x) = x

@inline function reset!(p::InlineProcess, inputs_overrides...)
    reset_loopidx!(getsession(p))
    # On the plan without the map, as the loop has it (`loop_algo`).
    initialized = _init_plan(getfield(p, :loop_algo), inputs_overrides...; lifetime = lifetime(p))
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
    return kwargs   # checked against the plan's `@input`s by the `LoopContext` constructor
end

# A context given to `run(ip)`: the run starts from it, so it becomes the process's context first.
@inline _set_inline_run_context!(p::InlineProcess, ::Nothing) = nothing
@inline function _set_inline_run_context!(p::InlineProcess, context)
    set_loop_context!(p, context)
    @assert _context(p) isa contexttype(p) "Wrong context shape for this process\n Context is of type $(typeof(_context(p))), but expected $(contexttype(p))."
    return nothing
end

# A lifetime given to `run(ip)`: numbered as the plan numbers its handles while compiling (`number_by_keymap`), and its
# `Var`s given their keys (`resolve_var_keys`; the key is found while compiling), before the call to the loop. The
# process's own lifetime got its keys when the process was built.
@inline _inline_run_lifetime(p::InlineProcess, algo, repeats, ::Nothing) = _inline_process_lifetime(algo, repeats, lifetime(p))
@inline _inline_run_lifetime(p::InlineProcess, algo, repeats, lt) =
    resolve_var_keys(_inline_process_lifetime(algo, repeats, number_by_keymap(lt, getfield(getregistry(getalgo(p)), :keymap))), _context(p))

"""
    run(ip; context, repeats, lifetime, threaded, inlined = Val(false), inputs...)

One run of `ip`, from the context it holds, returning the final context. `inlined = Val(true)` pastes the loop into
`run(ip)`: the context is not passed into a call and back (57-62 instead of 121-150 ns per `run(ip)` for the 616-byte
context of the 3D Ising model with one step per run), but the loop's machine code is made again for every set of
`Unique` handles at the first such run (first run 8.5-8.8 instead of 5.4-5.6 ms for 4 counters, 20.6-24.0 instead of
12.5-13.4 ms for 16), while the default call into the loop is compiled once for all (`run_session_loop`). The choice is in the `Val`'s type, so the branch is decided while compiling.
"""
@inline function Base.run(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, threaded=nothing, inlined::Val = Val(false), kwargs...)
    algo = getfield(p, :loop_algo)   # the plan without the map, as the loop runs it
    _set_inline_run_context!(p, context)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    run_lifetime = _inline_run_lifetime(p, algo, repeats, lifetime)

    if (isnothing(threaded) && isthreaded(p)) || threaded === true
        return Threads.@spawn _run_inline!(p, run_lifetime, runtime_inputs, inlined)
    elseif (isnothing(threaded) && isasync(p)) || threaded === :async
        return @async _run_inline!(p, run_lifetime, runtime_inputs, inlined)
    else
        return @inline _run_inline!(p, run_lifetime, runtime_inputs, inlined)
    end
end

@inline function run_nogen(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, threaded=nothing, kwargs...)
    algo = getfield(p, :loop_algo)   # the plan without the map, as the loop runs it
    _set_inline_run_context!(p, context)
    run_lifetime = _inline_run_lifetime(p, algo, repeats, lifetime)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, Val(false))
end

"""
    prepare_loop(ip::InlineProcess, inputs, lifetime, resume)

An `InlineProcess` runs every run in its one session, with its plan and context kept without the map (`loop_algo`,
`context`); the `LoopContext` is made from that context and the run's inputs. Typed, and inlined into `run(ip)`.
"""
@inline function prepare_loop(p::P, inputs::I, lt::LT, resume::R) where {P<:InlineProcess, I<:NamedTuple, LT, R<:Resuming}
    algo = getfield(p, :loop_algo)
    return getsession(p), algo, (@inline LoopContext(algo, getfield(p, :context), inputs, resume))
end

"""
One run of `p`: what `prepare_loop` makes (the session, the plan, the `LoopContext`), then the loop with those as
arguments, the same entry as a `Process` run (`run_session_loop`, a call whose arguments have no map, so the loop is
compiled once for every set of `Unique` handles; with `Val(true)`, the loop pasted in). The context it gives back
becomes the process's. Returns the run's result with the plan's registry (`with_plan_registry`), so `run(ip)[handle]`
is found from types, as `context(ip)[handle]` is.
"""
@inline function _run_inline!(p::InlineProcess, run_lifetime::LT, runtime_inputs::I, ::Val{inlined}) where {LT, I, inlined}
    session, algo, lc = @inline prepare_loop(p, runtime_inputs, run_lifetime, Resuming{false}())
    persistent_context, result = if inlined
        @inline loop(session, algo, lc, run_lifetime, Resuming{false}())
    else
        run_session_loop(loop, session, algo, lc, run_lifetime)
    end
    p.context = persistent_context
    return @inline with_plan_registry(p, result)
end

@inline function init_and_run(p::InlineProcess, inputs_overrides...)
    @inline makecontext!(p, inputs_overrides...)
    return run(p)
end

    
