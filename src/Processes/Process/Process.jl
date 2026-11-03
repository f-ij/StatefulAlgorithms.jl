#=
`Process`: a plan run on its own task, which the user can pause, resume and close while it runs. This file holds the
struct and its constructors. Its session (Session.jl), start and close listeners (Listeners.jl), getters and setters
(Accessors.jl), state context (Context.jl), loop setup (Loop.jl), copying (Copy.jl), the user calls on a running
process (Lifecycle.jl), its status and progress (Status.jl), the list of live processes (ProcessList.jl), showing
(Showing.jl) and precompiling (Precompile.jl) are in their own files. What every process type shares is one folder up
(Interface.jl, Hooks.jl, Construction.jl, Context.jl).
=#

export Process, getallocator, getnewallocator, getticks


mutable struct Process{F,C} <: AbstractProcess
    id::UUID
    algo::F
    lifetime::Lifetime
    # The process's state when its type is not the one stored in the plan (`algo`), which is in the process's type;
    # `nothing` when the plan holds it. Written only by `_sync_state_context!`.
    state_context::Union{Nothing, ProcessContext}
    # A paused run's runtime context (its inputs and declared locals), kept by the run's end (`_finish_run!`) and read by
    # the resumed run or by `close`, which both clear it. `nothing` when no run is paused.
    runtime_context::Union{Nothing, ProcessContext}
    timeout::Float64
    task::Union{Nothing, Task}
    # To make sure other processes don't interfere
    lock::ReentrantLock
    lastresult::Any
    rls::RuntimeListeners
    # The current or last run (Processes/Process/Session.jl): what the loop gets instead of the process. The run's
    # counters, times, cursor and the flags `pause(p)` and `close(p)` set are its fields.
    session::InteractiveSession{C}
end

"""
    Process(func, Init(...), Override(...); context, repeats, lifetime, timeout)

A process running `func`: the plan is initialized (or given its `context`) and the lifetime made from `repeats` or
`lifetime` (`_prepare_process`), then the process is built around them (`_construct_process`).
"""
Process(func::Func, inputs_overrides::Vararg{Any,N}) where {Func,N} = _build_process(func, inputs_overrides, nothing, nothing, (;))
# The keyword call, by hand: Julia's own specializes on the keywords' `NamedTuple`, whose type has the handles' uuids
# (a lifetime's `Var`), so it compiled once for every new set of handles.
function Core.kwcall(kw::NamedTuple, ::Type{Process}, func, inputs_overrides...)
    rest = Base.structdiff(kw, NamedTuple{(:context, :lifetime)})
    return _build_process(func, inputs_overrides, get(kw, :context, nothing), get(kw, :lifetime, nothing), rest)
end
function _build_process(func::Func, inputs_overrides::Tuple, context::C, lifetime::LT, kwargs::NamedTuple) where {Func, C, LT}
    algo, lifetime, timeout = _prepare_process(normalize_process_algo(func), inputs_overrides...; context, lifetime, kwargs...)
    return _construct_process(algo, lifetime, timeout)
end

"""The plan, initialized or with the given `context`, the lifetime and the timeout a new `Process` gets."""
function _prepare_process(algo::A, inputs_overrides::Vararg{Any,N}; context::C = nothing, repeats = nothing, lifetime = nothing, repeat = nothing, timeout = 1.0) where {A,N,C}
    lifetime = normalize_process_lifetime(algo, normalize_lifetime_arguments(algo, nothing, lifetime, repeats, repeat))
    algo = _process_constructor_algo(algo, context, inputs_overrides, lifetime)
    prepared_context = isnothing(context) ? getpersistentcontext(algo) : context
    algo = _with_lifecycle(algo, prepared_context, getstoredinits(algo), getstoredoverrides(algo))
    return algo, lifetime, timeout
end

"""The `Process` around a prepared plan: its session (made for the lifetime's type) and its place in `processlist`."""
function _construct_process(algo::F, lifetime::LT, timeout) where {F<:AbstractLoopAlgorithm, LT}
    C = typeof(loop_cursor(getplan(algo), Val(true)))
    session = InteractiveSession{C, LT}()
    p = Process{F, C}(uuid1(), algo, lifetime, nothing, nothing, timeout, nothing, Threads.ReentrantLock(), nothing, RuntimeListeners(), session)

    register_process!(p)
    schedule_loop_precompile!(p, lifetime)
    @DebugMode "Created process with id $(p.id), now preparing data"
    
    finalizer(remove_process!, p)
    return p
end

@inline function _process_constructor_algo(algo::LA, ::Nothing, inputs_overrides::Tuple{}, lifetime::LT) where {LA<:LoopSpec, LT}
    isnothing(getpersistentcontext(algo)) || return algo
    return init(algo; lifetime)
end

@inline function _process_constructor_algo(algo::LA, ::Nothing, inputs_overrides::IO, lifetime::LT) where {LA<:LoopSpec, IO<:Tuple, LT}
    return init(algo, inputs_overrides...; lifetime)
end

@inline function _process_constructor_algo(algo::LA, context::C, inputs_overrides::IO, lifetime::LT) where {LA<:LoopSpec, C, IO<:Tuple, LT}
    isempty(inputs_overrides) || error("Pass either an initialized `context` or init/override specs to `Process`, not both.")
    isnothing(getpersistentcontext(algo)) || return algo
    return _with_lifecycle(resolve(algo), nothing, getstoredinits(algo), getstoredoverrides(algo))
end

function Process(func, repeats::Int; overrides = tuple(), timeout = 1.0, context = nothing)
    overrides_tuple = overrides isa Tuple ? overrides : (overrides,)
    return Process(func, overrides_tuple...; repeats = repeats, timeout, context)
end

Base.:(==)(p1::Process, p2::Process) = p1.id == p2.id

function createfrom!(p1::Process, p2::Process)
    p1.algo = p2.algo
    _sync_state_context!(p1, context(p2))
    p1.runtime_context = nothing
    getsession(p1).loop_cursor = nothing
    p1.timeout = p2.timeout
    reset!(p1)
end
