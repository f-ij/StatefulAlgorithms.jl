export Process, getallocator, getnewallocator, getcontext, getticks


mutable struct Process{F,C} <: AbstractProcess
    id::UUID
    algo::F
    lifetime::Lifetime
    runtime_context::Union{Nothing, ProcessContext}
    timeout::Float64
    task::Union{Nothing, Task}
    # To make sure other processes don't interfere
    lock::ReentrantLock
    lastresult::Any
    rls::RuntimeListeners
    # The current or last run (Sessions/InteractiveSession.jl): what the loop gets instead of the process. The run's
    # counters, times, cursor and the flags `pause(p)` and `close(p)` set are its fields.
    session::InteractiveSession{C}
end

@setterGetter Process lock runtime_context session
"""
    getloopcursor(p::Process)

Return the loop cursor stored by a paused run, always as the plan's cursor type `C`.
Throws a `TypeError` when no cursor is stored.
"""
@inline getloopcursor(p::Process{F,C}) where {F,C} = getsession(p).loop_cursor::C

"""Whether the process should run (`false` after `pause(p)` or `close(p)`): its session's `shouldrun` flag."""
shouldrun(p::Process) = shouldrun(getsession(p))
"""Set whether the process should run."""
shouldrun(p::Process, val) = @atomic getsession(p).shouldrun = val

@inline getticks(p::Process) = getsession(p).tickidx
@inline reset_ticks!(p::Process) = (getsession(p).tickidx = UInt(1))

@inline function _process_state_label(p::Process)
    if ispaused(p)
        return "Paused"
    elseif isrunning(p)
        return "Running"
    elseif isdone(p)
        return "Finished"
    else
        return "Idle"
    end
end

@inline function _process_algo_summary(p::Process)
    return sprint(summary, getalgo(p))
end

"""
    _process_nested_show_value(value)

Return the user-facing value that should be rendered as a nested process field.

Loop runtime wrappers carry lifecycle data in their concrete type and fields.
For process display, the execution plan is the semantic value the user asked to
run, so it is shown directly instead of the wrapper object.
"""
@inline function _process_nested_show_value(value::LA) where {LA<:LoopAlgorithm}
    return getplan(value)
end

@inline _process_nested_show_value(value::V) where {V} = value

"""
    _process_nested_show_lines(io, value)

Render `value` for a nested `Process` tree field and return its display lines.
"""
function _process_nested_show_lines(io::IO, value::V) where {V}
    show_ctx = IOContext(io, :limit => get(io, :limit, false), :color => get(io, :color, false))
    return split(chomp(sprint(show, _process_nested_show_value(value); context = show_ctx)), '\n')
end

"""
    _process_context_show_lines(io, context)

Render a process context without globals and return its display lines.
"""
function _process_context_show_lines(io::IO, context::C) where {C<:ProcessContext}
    show_ctx = IOContext(io, :printcontextglobals => false, :limit => get(io, :limit, false), :color => get(io, :color, false))
    return split(chomp(sprint(show, context; context = show_ctx)), '\n')
end

"""
    _print_process_nested_field(io, branch, continuation, name, lines)

Print one multi-line field in a process tree with stable continuation
indentation.
"""
@inline function _process_nested_continuation_prefix(line::AbstractString, continuation::AbstractString)
    return (startswith(line, "├── ") || startswith(line, "└── ")) ? string(continuation, "    ") : continuation
end

function _print_process_nested_field(
    io::IO,
    branch::AbstractString,
    continuation::AbstractString,
    name::Symbol,
    lines::AbstractVector{<:AbstractString},
)
    label_prefix = string(branch, name, " = ")
    label_continuation = string(continuation, repeat(" ", Base.Unicode.textwidth(string(name, " = "))))
    _print_wrapped_prefixed(io, first(lines), label_prefix, label_continuation)
    for line in Iterators.drop(lines, 1)
        _print_wrapped_prefixed(io, line, continuation, _process_nested_continuation_prefix(line, continuation))
    end
    return nothing
end

@inline function _process_constructor_lifetime(repeats, lifetime, repeat)
    if !isnothing(repeat)
        isnothing(repeats) || error("Pass either `repeats = ...` or `repeat = ...`, not both.")
        repeats = repeat
    end

    if !isnothing(repeats)
        isnothing(lifetime) || error("Pass either `repeats = ...` or `lifetime = ...`, not both.")
        if repeats isa AbstractFloat && isinf(repeats)
            return Indefinite()
        else
            return repeats
        end
    end

    if isnothing(lifetime)
        return nothing
    elseif lifetime isa Lifetime
        return lifetime
    else
        error("Pass `repeats = ...` for repeat counts. The `lifetime` keyword is reserved for Lifetime objects.")
    end
end

function Process(func::Func, inputs_overrides::Vararg{Any,N}; context::C = nothing, repeats = nothing, lifetime = nothing, repeat = nothing, timeout = 1.0) where {Func,N,C}
    lifetime = _process_constructor_lifetime(repeats, lifetime, repeat)

    algo = normalize_process_algo(func)
    lifetime = normalize_process_lifetime(algo, lifetime)
    algo = _process_constructor_algo(algo, context, inputs_overrides, lifetime)
    return _finish_process_constructor(algo, context, lifetime, timeout)
end

@inline function _finish_process_constructor(algo::A, ::Nothing, lifetime::LT, timeout) where {A<:AbstractLoopAlgorithm, LT}
    prepared_context = getpersistentcontext(algo)
    return _finish_process_constructor_with_context(algo, prepared_context, lifetime, timeout)
end

@inline function _finish_process_constructor(algo::A, context::C, lifetime::LT, timeout) where {A<:AbstractLoopAlgorithm, C, LT}
    return _finish_process_constructor_with_context(algo, context, lifetime, timeout)
end

function _finish_process_constructor_with_context(algo::A, prepared_context::PC, lifetime::LT, timeout) where {A<:AbstractLoopAlgorithm, PC, LT}
    algo = _with_lifecycle(algo, prepared_context, getstoredinits(algo), getstoredoverrides(algo))

    C = typeof(loop_cursor(getplan(algo), Val(true)))
    session = InteractiveSession{C, typeof(lifetime)}()
    p = Process{typeof(algo),C}(uuid1(), algo, lifetime, nothing, timeout, nothing, Threads.ReentrantLock(), nothing, RuntimeListeners(), session)

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

getalgo(p::P) where {P<:Process} = p.algo
function context(p::P) where {P<:Process}
    runtime_context = p.runtime_context
    return isnothing(runtime_context) ? getpersistentcontext(getalgo(p)) : runtime_context
end

"""
Store one live process context in the dynamic runtime slot.

Use this while a `Process` is still resumable, for example after a pause or
before a run with per-call lifetime changes. The stored value may intentionally
deviate from the lifecycle context carried in `p.algo`.
"""
@inline function _store_runtime_context!(p::P, c::C) where {P<:Process, C}
    context(p, c)
    return c
end

"""
Commit one finished or reinitialized process context back onto the process.

When the context strips back to the same concrete type as the stored lifecycle
context, the lifecycle wrapper in `p.algo` is rebuilt so later runs keep using
the typed fast path. Only genuine shape changes fall back to the dynamic
`runtime_context` slot.
"""
@inline function commit_context!(p::P, c::C) where {P<:Process, C}
    algo = getalgo(p)
    persistent_context = getpersistentcontext(algo)

    # Preserve the typed lifecycle path whenever finalization returns to the
    # stored concrete context shape.
    if !isnothing(persistent_context) && typeof(c) === typeof(persistent_context)
        p.algo = _with_lifecycle(algo, c, getstoredinits(algo), getstoredoverrides(algo))
        p.runtime_context = nothing
    else
        p.runtime_context = c
    end
    return c
end

function context(p::P, c::C) where {P<:Process, C}
    p.runtime_context = c
    return c
end

@inline _has_typed_runtime_context(p::P) where {P<:Process} = isnothing(p.runtime_context)
@inline _typed_runtime_context(p::P) where {P<:Process} = getpersistentcontext(getalgo(p))

function getcontext(p::Process)
    return context(p)
end

getcontext(p::Process, context) = getcontext(p)[context]

runtimelisteners(::Any) = nothing
runtimelisteners(p::Process) = p.rls

isthreaded(p::Process) = true

"""
different loopfunction can be passed to the process through overrides
"""
function getloopfunc(p::Process)
    loop
end




# function Base.finalizer(p::Process)
#     quit(p)
#     delete!(processlist, p.id)
# end

function runtime(p::Process)
    @assert !isnothing(getsession(p).starttime) "Process has not started"
    return runtime_ns(p) / 1e9
end

function runtime_ns(p::Process)
    session = getsession(p)
    @assert !isnothing(session.starttime) "Process has not started"
    timens = isnothing(session.endtime) ? time_ns() - session.starttime : session.endtime - session.starttime
    return Int(timens)
end
export runtime_ns, runtime

# Exact time the process stopped in hh:mm:ss
function stop_time(p::Process)
    if isdone(p)
        return Dates.format(Dates.DateTime(getsession(p).endtime), "HH:MM:SS")
    else
        return nothing
    end
end

function createfrom!(p1::Process, p2::Process)
    p1.algo = p2.algo
    commit_context!(p1, context(p2))
    getsession(p1).loop_cursor = nothing
    p1.timeout = p2.timeout
    reset!(p1)
end



function timedwait(p, timeout = wait_timeout)
    t = time()
    
    while !isdone(p) && time() - t < timeout
    end

    return isdone(p)
end

@inline lock(p::Process) = lock(p.lock)
@inline lock(f, p::Process) = lock(f, p.lock)
@inline unlock(p::Process) =  unlock(p.lock)

"""
Runs the prepared task of a process on a thread
"""
function makeloop!(p::Process, inputs::NamedTuple = (;); threaded = true, loopfunc::LF = loop) where {LF}
    if _has_typed_runtime_context(p)
        runtime_context = _typed_runtime_context(p)
        return _makeloop!(p, inputs, lifetime(p), runtime_context; threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs; threaded, loopfunc)
    end
end

function makeloop!(p::Process, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF}
    if _has_typed_runtime_context(p)
        return _makeloop!(p, inputs, lt, _typed_runtime_context(p); threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs, lt; threaded, loopfunc)
    end
end

@noinline _makeloop_dynamic!(p::Process, inputs::NamedTuple; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lifetime(p), StatefulAlgorithms.context(p); threaded, loopfunc)

@noinline _makeloop_dynamic!(p::Process, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lt, StatefulAlgorithms.context(p); threaded, loopfunc)

function _makeloop!(p::Process, inputs::NamedTuple, lt, base_context; threaded = true, loopfunc::LF = loop) where {LF}
    session = create_session(p, lt)
    p.session = session
    @atomic session.paused = false
    @atomic session.shouldrun = true
    p.lastresult = nothing

    func = getalgo(p)
    inputs = _validate_runtime_inputs(func, inputs)
    return _makeloop_prepared!(p, session, func, base_context, lt, inputs; threaded, loopfunc)
end

"""
    create_session(p, lifetime) -> InteractiveSession

The session a run of `p` with `lifetime` runs in: the process's session when it has that lifetime's type, else a new
one with the same counters, times and thread. The caller sets it as the process's session, never while a run is going
on, so the loop and the process always share the one session.
"""
function create_session(p::Process{F, C}, lt::LT) where {F, C, LT}
    session = getsession(p)
    session isa InteractiveSession{C, LT} && return session
    return InteractiveSession{C, LT}(@atomic(session.shouldrun), @atomic(session.paused), session.loopidx, session.tickidx,
        session.starttime, session.endtime, session.loop_cursor, session.threadid)
end

function _makeloop_prepared!(p::P, session::S, func::F, runtime_context::C, lt::LT, inputs::I; threaded::Bool = true, loopfunc::LF = loop, resume::R = Resuming{false}()) where {P<:Process, S<:InteractiveSession, F, C, LT, I<:NamedTuple, LF, R<:Resuming}
    wait_loop_precompile!(p, func, runtime_context, lt, inputs, resume; loopfunc)
    if threaded
        p.task = Threads.@spawn _run_process_task(p, loopfunc, session, func, runtime_context, lt, inputs, resume)
    else
        p.task = @async _run_process_task(p, loopfunc, session, func, runtime_context, lt, inputs, resume)
    end
    return p
end

"""
What a `Process` task runs: the loop on the session (`run_session_loop`), then the run's end on the process
(`_finish_run!`). Its result is what `fetch(p)` returns.
"""
function _run_process_task(p::P, loopfunc::LF, session::S, func::F, runtime_context::C, lt::LT, inputs::I, resume::R) where {P<:Process, LF, S<:InteractiveSession, F, C, LT, I<:NamedTuple, R<:Resuming}
    persistent_context, returnvalue = run_session_loop(loopfunc, session, func, runtime_context, lt, inputs, resume)
    return _finish_run!(p, session, persistent_context, returnvalue)
end

"""
    _finish_run!(p, session, persistent_context, returnvalue) -> what the user gets (`fetch(p)`)

A run's end on the process: on a pause, the paused context is kept (with the cursor, kept by the loop in the session) so
the run resumes from it; otherwise the context is committed and the cursor dropped.
"""
function _finish_run!(p::Process, session::InteractiveSession, persistent_context, returnvalue)
    if _loop_ispaused(session)
        return _store_runtime_context!(p, persistent_context)
    end
    commit_context!(p, persistent_context)
    session.loop_cursor = nothing
    return returnvalue
end

function _resume_paused_loop!(p::Process; threaded = true)
    wait(p)
    session = getsession(p)
    @atomic session.shouldrun = true
    p.lastresult = nothing

    func = getalgo(p)
    runtime_context = StatefulAlgorithms.context(p)
    lt = lifetime(p)
    return _makeloop_prepared!(p, session, func, runtime_context, lt, (;); threaded, resume = Resuming{true}())
end

makeloop!(p::Process, lt::Lifetime; threaded = true, loopfunc::LF = loop) where {LF} =
    makeloop!(p, (;), lt; threaded, loopfunc)

"""
    reset!(process)

Reset selected `Process` fields without rebuilding its context.

This performs these exact mutations:

- in its session (`getsession(process)`): `loopidx = 1`, `tickidx = 1`, `paused = false`, `shouldrun = true`,
  `starttime = nothing`, `endtime = nothing`, and `loop_cursor = nothing`: the next run builds a fresh cursor, so every
  interval counter and resume point starts over.

It does not reset counters an algorithm keeps in its own value: a `Package`'s interval counter goes on from where it
was (TODO.md, "Packaging and threaded composites"). It does not change `process.runtime_context`, `process.task`, or
`process.lastresult`. It does not clear or replace values stored in
`context(process)`.
"""
function reset!(p::Process)
    session = getsession(p)
    reset_loopidx!(session)
    session.tickidx = UInt(1)
    session.loop_cursor = nothing
    @atomic session.paused = false
    @atomic session.shouldrun = true
    reset_times!(session)
    return p
end

### LINKING

link_process!(p1::Process, p2::Process) = push!(p1.linked_processes, p2)
unlink_process!(p1::Process, p2::Process) = filter!(x -> x != p2, p1.linked_processes)

function Base.show(io::IO, p::Process)
    if !isnothing(p.task) && p.task._isexception
        print(io, "Error in process")
        return display(p.task)
    end
    print(io, _process_state_label(p), " Process(", _process_algo_summary(p), ", lifetime=", lifetime(p), ", loopidx=", loopint(p), ")")

    return nothing
end

function Base.summary(io::IO, p::Process)
    print(io, "Process(", _process_algo_summary(p), ")")
end

function Base.show(io::IO, ::MIME"text/plain", p::Process)
    if !isnothing(p.task) && p.task._isexception
        print(io, "Error in process")
        return display(p.task)
    end

    println(io, "Process")
    println(io, "├── state = ", _process_state_label(p))
    println(io, "├── lifetime = ", lifetime(p))
    println(io, "├── loopidx = ", loopint(p))
    println(io, "├── timeout = ", p.timeout)

    algo_lines = _process_nested_show_lines(io, getalgo(p))
    _print_process_nested_field(io, "├── ", "│   ", :algo, algo_lines)

    context_lines = _process_context_show_lines(io, context(p))
    _print_process_nested_field(io, "└── ", "    ", :context, context_lines)

    return nothing
end
