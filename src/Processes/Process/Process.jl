export Process, getallocator, getnewallocator, getcontext, getticks


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

@setterGetter Process lock session
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
    lifetime = _process_constructor_lifetime(repeats, lifetime, repeat)
    lifetime = normalize_process_lifetime(algo, lifetime)
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

getalgo(p::P) where {P<:Process} = p.algo
"""
    context(p::Process)

The process's state context: the user's handle on the process's state, with the registry. Never a run's runtime
context: a paused run keeps that apart (`p.runtime_context`).
"""
function context(p::P) where {P<:Process}
    state_context = p.state_context
    return isnothing(state_context) ? getpersistentcontext(getalgo(p)) : state_context
end

"""
    _sync_state_context!(p, c)

Makes the values of `c` the process's state: a run's persistent context when it ends or pauses, or a context made by
init. The values (the subcontexts of `c`) go into the process's state context, which keeps everything else of the
user's handle (the registry). When the result has the type of the context stored in the plan, the plan's lifecycle
wrapper in `p.algo` is rebuilt with it, so later runs keep the typed path; otherwise it goes to `p.state_context`.
Leaves a paused run's runtime context alone.
"""
@inline function _sync_state_context!(p::P, c::C) where {P<:Process, C<:ProcessContext}
    synced = withsubcontexts(context(p), get_subcontexts(c))
    algo = getalgo(p)
    persistent_context = getpersistentcontext(algo)
    if !isnothing(persistent_context) && typeof(synced) === typeof(persistent_context)
        p.algo = _with_lifecycle(algo, synced, getstoredinits(algo), getstoredoverrides(algo))
        p.state_context = nothing
    else
        p.state_context = synced
    end
    return synced
end

# A `Process` manages its state context: the new context's values go into it.
makecontext!(p::Process, inputs_overrides...; lifetime=nothing) = _sync_state_context!(p, makecontext(p, inputs_overrides...; lifetime))

"""
    getruntimecontext(p::Process)

The runtime context a paused run of `p` keeps (its inputs and declared locals), or `nothing` when no run is paused.
Not exported: what the user works with is the state context, `context(p)`.
"""
getruntimecontext(p::Process) = p.runtime_context

@inline _has_typed_state_context(p::P) where {P<:Process} = isnothing(p.state_context)
@inline _typed_state_context(p::P) where {P<:Process} = getpersistentcontext(getalgo(p))

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
    _sync_state_context!(p1, context(p2))
    p1.runtime_context = nothing
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
    if _has_typed_state_context(p)
        return _makeloop!(p, inputs, lifetime(p), _typed_state_context(p); threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs; threaded, loopfunc)
    end
end

function makeloop!(p::Process, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF}
    if _has_typed_state_context(p)
        return _makeloop!(p, inputs, lt, _typed_state_context(p); threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs, lt; threaded, loopfunc)
    end
end

@noinline _makeloop_dynamic!(p::Process, inputs::NamedTuple; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lifetime(p), StatefulAlgorithms.context(p); threaded, loopfunc)

@noinline _makeloop_dynamic!(p::Process, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lt, StatefulAlgorithms.context(p); threaded, loopfunc)

function _makeloop!(p::Process, inputs::NamedTuple, lt, base_context; threaded = true, loopfunc::LF = loop) where {LF}
    session, func, lc = prepare_for_loop(p, base_context, inputs, lt, Resuming{false}())
    return _start_run!(p, session, func, lc, lt; threaded, loopfunc)
end

"""
    prepare_for_loop(p::Process, context, inputs, lifetime, resume)

A `Process` run runs in the process's session when it has `lifetime`'s type, else in a new one with the same counters
(`create_session`), which becomes the process's session. A new run starts from `context` (the process's state context)
and the run's inputs. A resumed run starts from `context` and the runtime context its pause kept, combined again into
one `LoopContext`; the process no longer keeps that runtime context (AbstractProcesses/Hooks.jl).
"""
function prepare_for_loop(p::Process, context::C, inputs::NamedTuple, lt::LT, resume::Resuming{false}) where {C<:ProcessContext, LT}
    session = create_session(p, lt)
    p.session = session
    func = getalgo(p)
    return session, func, with_inputs(make_loop_context(func, context), func, inputs)
end

function prepare_for_loop(p::Process, context::C, inputs::NamedTuple, lt::LT, resume::Resuming{true}) where {C<:ProcessContext, LT}
    session = create_session(p, lt)
    p.session = session
    func = getalgo(p)
    runtime_context = p.runtime_context
    p.runtime_context = nothing
    return session, func, LoopContext(context, runtime_context)
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

"""
    _start_run!(p, session, func, loop_context, lifetime; threaded, loopfunc, resume)

Starts a run of `p` with what `prepare_for_loop` made: the session is set running, then the task running the loop is
scheduled.
"""
function _start_run!(p::P, session::S, func::F, lc::LC, lt::LT; threaded::Bool = true, loopfunc::LF = loop, resume::R = Resuming{false}()) where {P<:Process, S<:InteractiveSession, F, LC<:LoopContext, LT, LF, isresuming, R<:Resuming{isresuming}}
    # A resumed run clears the pause flag in the loop, after reading the cursor the pause kept.
    isresuming || @atomic session.paused = false
    @atomic session.shouldrun = true
    p.lastresult = nothing
    wait_loop_precompile!(p, func, lc, lt, resume; loopfunc)
    # The task runs `body` itself (as `Threads.@spawn` and `@async` do with a closure around it): its type is known
    # before the task exists, so it can be compiled ahead (Processes/Process/ProcessPrecompile.jl).
    body = ProcessTaskBody(p, loopfunc, session, func, lc, lt, resume)
    task = Task(body)
    if threaded
        task.sticky = false
        Threads._spawn_set_thrpool(task, :default)
    end
    p.task = schedule(task)
    return p
end

"""
    ProcessTaskBody(p, loopfunc, session, func, loop_context, lifetime, resume)

What a `Process` task runs, as a value: calling it runs `_run_process_task` with its fields. A struct, not a closure,
so its type is known before the task exists.
"""
struct ProcessTaskBody{P, LF, S, F, LC, LT, R}
    p::P
    loopfunc::LF
    session::S
    func::F
    loop_context::LC
    lifetime::LT
    resume::R
end
(body::ProcessTaskBody)() = _run_process_task(body.p, body.loopfunc, body.session, body.func, body.loop_context, body.lifetime, body.resume)

"""
What a `Process` task runs: the loop on the session (`run_session_loop`), then the run's end on the process
(`_finish_run!`). Its result is what `fetch(p)` returns.
"""
function _run_process_task(p::P, loopfunc::LF, session::S, func::F, lc::LC, lt::LT, resume::R) where {P<:Process, LF, S<:InteractiveSession, F, LC<:LoopContext, LT, R<:Resuming}
    persistent_context, returnvalue = run_session_loop(loopfunc, session, func, lc, lt, resume)
    return _finish_run!(p, session, persistent_context, returnvalue)
end

"""
    _finish_run!(p, session, persistent_context, returnvalue) -> what the user gets (`fetch(p)`)

A run's end on the process. On a pause the loop gives back its `LoopContext` as `returnvalue`, and it is taken apart:
the persistent context's values go into the process's state context (`_sync_state_context!`), the runtime context into
`p.runtime_context`; the cursor is kept by the loop in the session. The run resumes from these and the user gets the
state context. Otherwise the persistent context's values go into the state context and the cursor is dropped.
"""
function _finish_run!(p::Process, session::InteractiveSession, persistent_context, returnvalue)
    if _loop_ispaused(session)
        _sync_state_context!(p, getpersistent(returnvalue))
        p.runtime_context = getruntime(returnvalue)
        return context(p)
    end
    _sync_state_context!(p, persistent_context)
    session.loop_cursor = nothing
    return returnvalue
end

function _resume_paused_loop!(p::Process; threaded = true)
    wait(p)
    lt = lifetime(p)
    session, func, lc = prepare_for_loop(p, StatefulAlgorithms.context(p), (;), lt, Resuming{true}())
    return _start_run!(p, session, func, lc, lt; threaded, resume = Resuming{true}())
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
was (TODO.md, "Packaging and threaded composites"). It does not change `process.state_context`, `process.runtime_context`, `process.task`, or
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
