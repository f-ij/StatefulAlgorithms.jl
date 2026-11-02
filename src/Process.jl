export Process, getallocator, getnewallocator, getcontext, getticks


mutable struct Process{F,C} <: AbstractProcess
    list_ref::UUID   # its key in `processlist`
    # The plan, its registry with the plan's `UniqueKeyMap`: the only place the process has the map, so its type has it
    # and `context(p)[handle]` is found from types. A run hands the plan and the context to the loop without it
    # (`_makeloop!`).
    algo::F
    lifetime::Lifetime # its `Var`s numbered as the plan numbers its handles
    # A paused run's context, kept by the run's end (`_finish_run!`) and read only by a resumed run and by `close`
    # (which ends the run: cleanup, commit, cleared). `nothing` when no run is paused. With the plan's registry, as
    # every context the process keeps.
    paused_context::Union{Nothing, ProcessContext}
    # A committed context whose type is not the plan's stored one (`commit_context!`): it cannot go into `algo`, whose
    # type is in the process's. `nothing` when the plan holds the context. A run from it is dispatched at run time.
    reshaped_context::Union{Nothing, ProcessContext}
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

@setterGetter Process lock paused_context reshaped_context session
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

A process running `func`. Resolves it first (untyped) and initializes the plan without the plan's `UniqueKeyMap`
(`strip_keymap`, `number_by_keymap_dynamic`), so a new set of `Unique` handles compiles none of that again; the
initialized plan gets its registry with the map back, and the process holds it so (`algo`).
"""
Base.@nospecializeinfer Process(@nospecialize(func), @nospecialize(inputs_overrides...)) =
    _build_process(func, inputs_overrides, nothing, nothing, (;))
# The keyword call, by hand: Julia's own specializes on the keywords' `NamedTuple`, whose type has the handles' uuids
# (a lifetime's `Var`), so it compiled once for every new set of handles (2.5 ms each).
Base.@nospecializeinfer function Core.kwcall(@nospecialize(kw::NamedTuple), ::Type{Process}, @nospecialize(func), @nospecialize(inputs_overrides...))
    rest = Base.structdiff(kw, NamedTuple{(:context, :lifetime)})
    return _build_process(func, inputs_overrides, get(kw, :context, nothing), get(kw, :lifetime, nothing), rest)
end
Base.@nospecializeinfer function _build_process(@nospecialize(func), @nospecialize(inputs_overrides::Tuple), @nospecialize(context), @nospecialize(lifetime), @nospecialize(kwargs::NamedTuple))
    algo = func isa LoopSpec ? func : normalize_process_algo(func)
    algo isa LoopSpec && (algo = resolve(algo))
    keymap = getkeymap(algo)
    # The lifetime is not part of the plan: its `Var`s get the plan's numbers here, while the map is known.
    algo, lifetime, timeout = _prepare_process(strip_keymap(algo), inputs_overrides...; context = strip_keymap(context),
        lifetime = number_by_keymap_dynamic(lifetime, keymap), kwargs...)
    return _construct_process(with_keymap(algo, keymap), lifetime, timeout)
end

function _prepare_process(algo::A, inputs_overrides::Vararg{Any,N}; context::C = nothing, repeats = nothing, lifetime = nothing, repeat = nothing, timeout = 1.0) where {A,N,C}
    lifetime = _process_constructor_lifetime(repeats, lifetime, repeat)
    lifetime = normalize_process_lifetime(algo, lifetime)
    algo = _process_constructor_algo(algo, context, inputs_overrides, lifetime)
    prepared_context = isnothing(context) ? getpersistentcontext(algo) : context
    algo = _with_lifecycle(algo, prepared_context, getstoredinits(algo), getstoredoverrides(algo))
    return algo, lifetime, timeout
end

# The only constructor step typed on the map (in the plan's registry): compiled once per set of `Unique` handles, and small.
function _construct_process(algo::F, lifetime::LT, timeout) where {F<:AbstractLoopAlgorithm, LT}
    C = typeof(loop_cursor(getplan(algo), Val(true)))
    session = InteractiveSession{C, LT}()
    p = Process{F, C}(uuid1(), algo, lifetime, nothing, nothing, timeout, nothing, Threads.ReentrantLock(), nothing, RuntimeListeners(), session)

    register_process!(p)
    # What a first run calls with `p` is typed on the map, so compiled for every set of `Unique` handles: compiled here,
    # so the first `run` does not wait for it (src/PrecompileInterface.jl).
    precompile_interface(p)
    @DebugMode "Created process $(p.list_ref), now preparing data"

    finalizer(remove_process!, p)
    return p
end

@inline function _process_constructor_algo(algo::LA, ::Nothing, inputs_overrides::Tuple{}, lifetime::LT) where {LA<:LoopSpec, LT}
    isnothing(getpersistentcontext(algo)) || return algo
    return _init_plan(algo; lifetime)
end

@inline function _process_constructor_algo(algo::LA, ::Nothing, inputs_overrides::IO, lifetime::LT) where {LA<:LoopSpec, IO<:Tuple, LT}
    return _init_plan(algo, inputs_overrides...; lifetime)
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

Base.:(==)(p1::Process, p2::Process) = p1.list_ref == p2.list_ref

getalgo(p::P) where {P<:Process} = p.algo
"""The process's context: a paused run's, else a reshaped one, else the plan's. Each has the plan's registry, with the
plan's `UniqueKeyMap`. Untyped, its fields read with `getfield`: the process's type has the map, so a typed method would
compile once for every set of `Unique` handles."""
Base.@nospecializeinfer function _context(@nospecialize(p::Process))
    paused = getfield(p, :paused_context)
    isnothing(paused) || return paused
    reshaped = getfield(p, :reshaped_context)
    isnothing(reshaped) || return reshaped
    algo = getfield(p, :algo)
    algo isa FinalizedAlgorithm && (algo = getfield(algo, :inner))
    return getfield(algo, :context)
end

"""
    context(p)

The process's context (`_context`): its registry has the plan's `UniqueKeyMap`, so a `Unique` handle the user holds is
a key found from types: `context(p)[handle]`.
"""
Base.@nospecializeinfer context(@nospecialize(p::Process)) = _context(p)

"""
    with_plan_registry(p, x)

`x`, a context or plan from the loop's side (its registry without the map), with the registry of `p`'s plan, which has
the plan's `UniqueKeyMap`: the way back from the loop to what the process keeps and hands out. Another value as it is.
Untyped: the context's type can change between runs.
"""
Base.@nospecializeinfer with_plan_registry(@nospecialize(p::Process), @nospecialize(x)) = with_keymap(x, getkeymap(getalgo(p)))

"""
Commit one finished or reinitialized process context back onto the process. The plan's lifecycle is rebuilt on the plan
and `c` without the map (`strip_keymap`), so it compiles once for every set of `Unique` handles; what the process keeps
gets the plan's registry back (`with_plan_registry`).

When the context strips back to the same concrete type as the stored lifecycle
context, the lifecycle wrapper in `p.algo` is rebuilt so later runs keep using
the typed fast path. Only genuine shape changes go to `reshaped_context`. Ends a paused run's state:
`paused_context` is cleared.
"""
Base.@nospecializeinfer function commit_context!(@nospecialize(p::Process), @nospecialize(c))
    loop_algo = strip_keymap(getfield(p, :algo))
    loop_c = strip_keymap(c)
    persistent_context = getpersistentcontext(loop_algo)

    # Preserve the typed lifecycle path whenever finalization returns to the
    # stored concrete context shape.
    if !isnothing(persistent_context) && typeof(loop_c) === typeof(persistent_context)
        setfield!(p, :algo, with_plan_registry(p, _with_lifecycle(loop_algo, loop_c, getstoredinits(loop_algo), getstoredoverrides(loop_algo))))
        setfield!(p, :reshaped_context, nothing)
    else
        setfield!(p, :reshaped_context, with_plan_registry(p, loop_c))
    end
    setfield!(p, :paused_context, nothing)
    return _context(p)
end

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
#     delete!(processlist, p.list_ref)
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
    commit_context!(p1, _context(p2))
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
# The lifetime, the plan and the context are read from fields of abstract type, so the call into `_makeloop!` is
# dispatched on the types `prepare_loop` gives back; from there on everything is typed.
makeloop!(p::Process, inputs::NamedTuple = (;); threaded = true, loopfunc::LF = loop) where {LF} =
    makeloop!(p, inputs, lifetime(p); threaded, loopfunc)

# Not specialized on the process (its type has the map): compiled once for every set of `Unique` handles.
Base.@nospecializeinfer function makeloop!(@nospecialize(p::Process), inputs::NamedTuple, @nospecialize(lt); threaded = true, loopfunc::LF = loop) where {LF}
    session, func, lc = prepare_loop(p, inputs, lt, Resuming{false}())
    return _makeloop!(p, session, func, lc, lt; threaded, loopfunc)
end

"""
    prepare_loop(p::Process, inputs, lifetime, resume)

A `Process` run runs in the process's session when it has `lifetime`'s type, else in a new one with the same counters
(`create_session`), which becomes the process's session. The plan is the process's without the map (`strip_keymap`);
the run starts from the process's context, or from the paused context when it resumes. Not specialized on the process
(its type has the map): compiled once for every set of `Unique` handles.
"""
Base.@nospecializeinfer function prepare_loop(@nospecialize(p::Process), inputs::NamedTuple, @nospecialize(lt), ::Resuming{isresuming}) where {isresuming}
    # `setfield!`, a builtin: `p.session = ...` here would compile `setproperty!` for every process type.
    session = create_session(p, lt)
    setfield!(p, :session, session)
    func = strip_keymap(getalgo(p))
    start_context = isresuming ? p.paused_context : _context(p)
    return session, func, LoopContext(func, start_context, inputs, Resuming{isresuming}())
end

"""
    create_session(p, lifetime) -> InteractiveSession

The session a run of `p` with `lifetime` runs in: the process's session when it has that lifetime's type, else a new
one with the same counters, times and thread (as one `Process` kept them before sessions). The caller sets it as the
process's session, never while a run is going on, so the loop and the process always share the one session.
"""
function create_session(p::Process{F, C}, lt::LT) where {F, C, LT}
    session = getsession(p)
    session isa InteractiveSession{C, LT} && return session
    return InteractiveSession{C, LT}(@atomic(session.shouldrun), @atomic(session.paused), session.loopidx, session.tickidx,
        session.starttime, session.endtime, session.loop_cursor, session.threadid)
end

"""
    _makeloop!(p, session, func, loop_context, lifetime; threaded, loopfunc, resume)

Starts a run of `p` with what `prepare_loop` made: the session is set running, then the task running the loop is
scheduled. `func` (the plan) and `loop_context` have no map: the loop never reads it, and without it the loop is
compiled once for every set of `Unique` handles.
"""
function _makeloop!(p::P, session::S, func::F, lc::LC, lt::LT; threaded::Bool = true, loopfunc::LF = loop, resume::R = Resuming{false}()) where {P<:Process, S<:InteractiveSession, F, LC<:LoopContext, LT, LF, isresuming, R<:Resuming{isresuming}}
    # A resumed run clears the pause flag in the loop, after reading the cursor the pause kept.
    isresuming || @atomic session.paused = false
    @atomic session.shouldrun = true
    p.lastresult = nothing
    # The task runs `body` itself (as `Threads.@spawn` and `@async` do with a closure around it): its type is known
    # when the process is built, so it is compiled then.
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
so its type is known before the task exists and it is compiled when the process is built (`precompile_interface`).
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
What a `Process` task runs: the loop on the session (`run_session_loop`, a call whose arguments have no map in their
types, so the loop is compiled once for every set of `Unique` handles), then the run's end on the process
(`_finish_run!`). Its result is what `fetch(p)` returns.
"""
function _run_process_task(p::P, loopfunc::LF, session::S, func::F, lc::LC, lt::LT, resume::R) where {P<:Process, LF, S<:InteractiveSession, F, LC<:LoopContext, LT, R<:Resuming}
    persistent_context, returnvalue = run_session_loop(loopfunc, session, func, lc, lt, resume)
    return _finish_run!(p, session, persistent_context, returnvalue)
end

"""
    _finish_run!(p, session, persistent_context, returnvalue) -> what the user gets (`fetch(p)`)

A run's end on the process: on a pause, the paused context is kept (with the cursor, kept by the loop in the session) so
the run resumes from it; otherwise the context is committed and the cursor dropped. What the loop gave back has no map:
the contexts kept and the result get the plan's registry (`with_plan_registry`).
"""
function _finish_run!(p::Process, session::InteractiveSession, persistent_context, returnvalue)
    if _loop_ispaused(session)
        p.paused_context = with_plan_registry(p, persistent_context)
        return p.paused_context
    end
    committed = commit_context!(p, persistent_context)
    session.loop_cursor = nothing
    return returnvalue === persistent_context ? committed : with_plan_registry(p, returnvalue)
end

function _resume_paused_loop!(p::Process; threaded = true)
    wait(p)
    lt = lifetime(p)
    session, func, lc = prepare_loop(p, (;), lt, Resuming{true}())
    return _makeloop!(p, session, func, lc, lt; threaded, resume = Resuming{true}())
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
was (TODO.md, "Packaging and threaded composites"). It does not change `process.paused_context`, `process.task`, or
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

    context_lines = _process_context_show_lines(io, _context(p))
    _print_process_nested_field(io, "└── ", "    ", :context, context_lines)

    return nothing
end
