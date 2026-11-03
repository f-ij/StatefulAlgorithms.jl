export InlineProcess, InlineProcessAlgorithm, run, reset!
"""
A fully typed process that is meant for inlining into other Functions
Mainly used to compose algorithms in tight loops, plugging into the ProcessLoopAlgorithm system

This doesn't provide the multitasking features of Process, but is faster to restart. A run runs in the caller's task:
running on a task of its own is what `Process` is for.
"""
mutable struct InlineProcess{TD,ContextType, Lt} <: AbstractProcess
    const id::UUID
    const algo::TD
    # The process's context: the loop gets it as an argument (`run_session_loop`) and gives the new one back, which
    # `run(ip)` stores here.
    context::ContextType
    consumed::Bool
    lifetime::Lt
    # The run's counter, one session for every run (Processes/InlineProcess/Session.jl): what the loop gets instead of the
    # process.
    const session::InlineSession
end
#TODO Improve context semantics
contexttype(::Union{InlineProcess{TD,ContextType}, Type{<:InlineProcess{TD,ContextType}}}) where {TD,ContextType} = ContextType

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
    InlineProcess(func, Init(...), Override(...); repeats, lifetime, context)

An inline process running `func`: the plan is initialized (or given its `context`) and the lifetime made from `repeats`
or `lifetime` (`_prepare_inline_process`), then the process is built around them (`_construct_inline_process`).
"""
InlineProcess(func::Func, inputs_overrides::Vararg{Any,N}) where {Func,N} =
    _build_inline_process(func, inputs_overrides, nothing, nothing, (;))
# The keyword call, by hand: Julia's own specializes on the keywords' `NamedTuple`, whose type has the handles' uuids
# (a lifetime's `Var`), so it compiled once for every new set of handles.
function Core.kwcall(kw::NamedTuple, ::Type{InlineProcess}, func, inputs_overrides...)
    rest = Base.structdiff(kw, NamedTuple{(:context, :lifetime)})
    return _build_inline_process(func, inputs_overrides, get(kw, :context, nothing), get(kw, :lifetime, nothing), rest)
end
function _build_inline_process(func::Func, inputs_overrides::Tuple, context::C, lifetime::LT, kwargs::NamedTuple) where {Func, C, LT}
    algo, prepared_context, lifetime = _prepare_inline_process(normalize_process_algo(func), inputs_overrides...; context, lifetime, kwargs...)
    return _construct_inline_process(algo, prepared_context, lifetime)
end

"""The plan, initialized or with the given `context`, its context and the lifetime a new `InlineProcess` gets."""
@inline function _prepare_inline_process(algo, inputs_overrides...; repeats=nothing, lifetime=nothing, context=nothing)
    lifetime = _inline_process_lifetime(algo, repeats, lifetime)
    lifetime = normalize_process_lifetime(algo, lifetime)
    algo = isnothing(context) ? init(algo, inputs_overrides...; lifetime) : _with_lifecycle(resolve(algo), context, (), ())
    return algo, getpersistentcontext(algo), lifetime
end

"""The `InlineProcess` around a prepared plan, its context and lifetime, with its one session."""
_construct_inline_process(algo::TD, context::C, lifetime::Lt) where {TD, C, Lt} =
    InlineProcess{TD, C, Lt}(uuid1(), algo, context, false, lifetime, InlineSession())

@inline lifetime(ip::IP) where {IP<:InlineProcess} = ip.lifetime
@inline getcontext(ip::IP) where {IP<:InlineProcess} = context(ip)

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
The runtime inputs for one `InlineProcess` execution; they are checked against the plan's `@input`s where the run's
`LoopContext` is made (`prepare_for_loop`).

`InlineProcess` has a fixed context type after construction. Per-run data is
therefore limited to declared `@input` keywords; structural reinitialization
stays on `reset!`, where the process can rebuild its persistent context.
"""
@inline function _inline_runtime_inputs(algo::A, inputs_overrides::IO, kwargs::K) where {A<:AbstractLoopAlgorithm, IO<:Tuple, K<:NamedTuple}
    isempty(inputs_overrides) || error("InlineProcess run accepts runtime inputs as keywords only. Use reset!(p, specs...) to reinitialize the context.")
    return kwargs
end

# A context given to `run(ip)`: the run starts from it, so it becomes the process's context first.
@inline _set_inline_run_context!(p::InlineProcess, ::Nothing) = nothing
@inline function _set_inline_run_context!(p::InlineProcess, context)
    @assert context isa contexttype(p) "Wrong context shape for this process\n Context is of type $(typeof(context)), but expected $(contexttype(p))."
    p.context = context
    return nothing
end

"""
    run(ip; context, repeats, lifetime, inlined = Val(false), inputs...)

One run of `ip` in the caller's task, from the context it holds (or `context`, which becomes its context), returning
the run's result. `inlined = Val(true)` pastes the loop into `run(ip)`: the context is not passed into a call and back
(57-62 instead of 121-150 ns per `run(ip)` for the 616-byte context of the 3D Ising model with one step per run,
measured on `refactor/plan-compiles`), but the loop's machine code is then made again for every caller, while the
default call into the loop (`run_session_loop`) is compiled once. As a `Val`, the branch is decided while compiling.
"""
@inline function Base.run(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, inlined::Val = Val(false), kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    run_lifetime = _inline_process_lifetime(algo, repeats, isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime)
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, inlined)
end

@inline function run_nogen(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    run_lifetime = _inline_process_lifetime(algo, repeats, isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, Val(false))
end

"""
    prepare_for_loop(ip::InlineProcess, context, inputs, lifetime, resume)

An `InlineProcess` run runs in the process's one session, on its plan, from `context` and the run's inputs
(AbstractProcesses/Hooks.jl). An `InlineProcess` cannot pause, so it never resumes.
"""
@inline prepare_for_loop(ip::IP, context::C, inputs::I, lt::LT, resume::Resuming{false}) where {IP<:InlineProcess, C<:ProcessContext, I<:NamedTuple, LT} =
    getsession(ip), getalgo(ip), (@inline with_inputs((@inline make_loop_context(getalgo(ip), context)), getalgo(ip), inputs))

"""
One run of `p`: what `prepare_for_loop` makes (the session, the plan, the `LoopContext`), then the loop with those as
arguments, the same entry as a `Process` run (`run_session_loop`; with `Val(true)`, the loop pasted in). The context it
gives back becomes the process's.
"""
@inline function _run_inline!(p::InlineProcess, run_lifetime::LT, runtime_inputs::I, ::Val{inlined}) where {LT, I, inlined}
    session, algo, lc = @inline prepare_for_loop(p, context(p), runtime_inputs, run_lifetime, Resuming{false}())
    persistent_context, result = if inlined
        @inline loop(session, algo, lc, run_lifetime, Resuming{false}())
    else
        run_session_loop(loop, session, algo, lc, run_lifetime)
    end
    p.context = persistent_context
    return result
end

@inline function init_and_run(p::InlineProcess, inputs_overrides...)
    @inline makecontext!(p, inputs_overrides...)
    return run(p)
end
