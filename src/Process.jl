export Process, getallocator, getnewallocator, getcontext, getticks


mutable struct Process{F,LT,C} <: AbstractProcess
    id::UUID
    algo::F
    lifetime::Lifetime
    runtime_context::Union{Nothing, ProcessContext}
    loop_cursor::Union{Nothing, C} # Kept across pause/resume; C is fixed by the plan type
    timeout::Float64
    task::Union{Nothing, Task}
    loopidx::UInt # To track the current loop index for resuming
    tickidx::UInt # To track ticks for performance monitoring
    # To make sure other processes don't interfere
    lock::ReentrantLock 
    @atomic shouldrun::Bool
    @atomic paused::Bool
    starttime ::Union{Nothing, Float64, UInt64}
    endtime::Union{Nothing, Float64, UInt64}
    lastresult::Any
    # linked_processes::Vector{Process} # Maybe do only with UUIDs for flexibility
    # allocator::Allocator
    rls::RuntimeListeners
    threadid::Int
    # The plan's `UniqueKeyMap` (or `nothing`), taken out of the registry the loop runs on (`strip_keymap`) and put
    # back into the contexts handed to the user (`context(p)`, `fetch(p)`). Untyped, so the map's type (new for every
    # set of `Unique` handles) is not in the `Process` type the loop is compiled for.
    keymap::Any
    # The context handed to the user (`context(p)`): the process's context with `keymap` put back, built once each time
    # the process's context changes (at loop exit, `commit_context!`, `context(p, c)`; `set_user_context!`).
    user_context::Any
end

@setterGetter Process lock shouldrun runtime_context
"""
    getloopcursor(p::Process)

Return the loop cursor stored by a paused run, always as the plan's cursor type `C`.
Throws a `TypeError` when no cursor is stored.
"""
@inline getloopcursor(p::Process{F,LT,C}) where {F,LT,C} = p.loop_cursor::C

"""
Get value of run of a process, denoting wether it should run or not
"""
shouldrun(p::Process) = @atomic :monotonic p.shouldrun   # atomic (no ordering barrier): re-read every step, so pause/close are seen

"""
    process_breakcondition(p::Process) -> Bool

Extends the hook `process_breakcondition` (AbstractProcesses/Hooks.jl): a `Process` is interrupted when its `shouldrun`
flag is off (`pause` or `close`). Checked after every step and after every routine repeat. Routine repeats can run for
a very long time, so the check must stay per repeat: checking only once per routine child (or every n repeats) would
make a pause or close wait for the child's remaining repeats and kill interactivity. The check costs a little per
repeat and keeps the compiler from writing a routine's repeats out one after another (perf/README.md shows the cost).
"""
@inline process_breakcondition(p::P) where {P<:Process} = @inline !shouldrun(p)
"""
Set value of run of a process, denoting wether it should run or not
"""
shouldrun(p::Process, val) = @atomic p.shouldrun = val

# Loop counting
@inline looptick!(p::Process) = (p.tickidx = p.tickidx + UInt(1))
@inline tick!(p::Process) = (p.tickidx = p.tickidx + UInt(1))
@inline getticks(p::Process) = p.tickidx
@inline reset_ticks!(p::Process) = (p.tickidx = UInt(1))

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

A process running `func`. Resolves it first (untyped), keeps the plan's `UniqueKeyMap` on the process and builds the
process on the plan without it (`strip_keymap`), so a new set of `Unique` handles compiles nothing again.
"""
Base.@nospecializeinfer function Process(@nospecialize(func), @nospecialize(inputs_overrides...); context = nothing, @nospecialize(lifetime = nothing), kwargs...)
    algo = func isa LoopSpec ? func : normalize_process_algo(func)
    algo isa LoopSpec && (algo = resolve(algo))
    keymap = getkeymap(algo)
    # The lifetime is not part of the plan: its `Var`s get the plan's numbers here, while the map is known.
    p = _new_process(strip_keymap(algo), inputs_overrides...; context = strip_keymap(context),
        lifetime = number_by_keymap(lifetime, keymap), kwargs...)
    setfield!(p, :keymap, keymap)   # not `p.keymap = `: that compiles `setproperty!` for every map type
    set_user_context!(p, _context(p))
    return p
end

function _new_process(algo::A, inputs_overrides::Vararg{Any,N}; context::C = nothing, repeats = nothing, lifetime = nothing, repeat = nothing, timeout = 1.0) where {A,N,C}
    lifetime = _process_constructor_lifetime(repeats, lifetime, repeat)
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

    # p = Process(uuid1(), context, td, timeout, nothing, UInt(1), UInt(1), Threads.ReentrantLock(), false, true, nothing, nothing, Arena(), RuntimeListeners(), 0)
    C = typeof(loop_cursor(getplan(algo), Val(true)))
    p = Process{typeof(algo),typeof(lifetime),C}(uuid1(), algo, lifetime, nothing, nothing, timeout, nothing, UInt(1), UInt(1), Threads.ReentrantLock(), false, true, nothing, nothing, nothing, RuntimeListeners(), 0, nothing, nothing)

    register_process!(p)
    schedule_loop_precompile!(p, lifetime)
    @DebugMode "Created process with id $(p.id), now preparing data"
    
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

Base.:(==)(p1::Process, p2::Process) = p1.id == p2.id

getalgo(p::P) where {P<:Process} = p.algo
"""The process's context as SA works with it: its registry stores `Unique` handles numbered (see `context`)."""
function _context(p::P) where {P<:Process}
    runtime_context = p.runtime_context
    return isnothing(runtime_context) ? getpersistentcontext(getalgo(p)) : runtime_context
end

"""
    context(p)

The process's context, with the plan's `UniqueKeyMap` back in its registry (`with_keymap`), so a `Unique` handle the
user holds is a key found from types: `context(p)[handle]`. Built when the process's context changes
(`set_user_context!`), not here.
"""
Base.@nospecializeinfer context(@nospecialize(p::Process)) = getfield(p, :user_context)

"""
    set_user_context!(process, c)

Builds the context `process` hands to the user from its context `c`: `c` with the plan's `UniqueKeyMap` put back
(`with_keymap`), stored in the process's `user_context` field. Called each time the process's context changes. Untyped,
so the loop that calls it at its exit compiles nothing per uuid.
"""
Base.@nospecializeinfer function set_user_context!(@nospecialize(process::AbstractProcess), @nospecialize(c))
    setfield!(process, :user_context, with_keymap(c, getfield(process, :keymap)))
    return nothing
end

"""`x` (a context or another value a process hands to the user) with the process's `UniqueKeyMap` put back. Untyped."""
Base.@nospecializeinfer with_process_keymap(@nospecialize(process::AbstractProcess), @nospecialize(x)) =
    with_keymap(x, getfield(process, :keymap))

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
    set_user_context!(p, c)
    return c
end

function context(p::P, c::C) where {P<:Process, C}
    p.runtime_context = strip_keymap(c)   # a context the user got from `context(p)` carries the map
    set_user_context!(p, p.runtime_context)
    return c
end

@inline _has_typed_runtime_context(p::P) where {P<:Process} = isnothing(p.runtime_context)
@inline _typed_runtime_context(p::P) where {P<:Process} = getpersistentcontext(getalgo(p))

function getcontext(p::Process)
    return context(p)
end

getcontext(p::Process, context) = getcontext(p)[context]
set_starttime!(p::Process) = p.starttime = time_ns()
set_endtime!(p::Process) = p.endtime = time_ns()
reset_times!(p::Process) = (p.starttime = nothing; p.endtime = nothing)

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
    @assert !isnothing(p.starttime) "Process has not started"
    return runtime_ns(p) / 1e9
end

function runtime_ns(p::Process)
    @assert !isnothing(p.starttime) "Process has not started"
    timens = isnothing(p.endtime) ? time_ns() - p.starttime : p.endtime - p.starttime
    return Int(timens)
end
export runtime_ns, runtime

# Exact time the process stopped in hh:mm:ss
function stop_time(p::Process)
    if isdone(p)
        return Dates.format(Dates.DateTime(p.endtime), "HH:MM:SS")
    else
        return nothing
    end
end

function createfrom!(p1::Process, p2::Process)
    p1.algo = p2.algo
    commit_context!(p1, _context(p2))
    p1.loop_cursor = nothing
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
    _makeloop!(p, inputs, lifetime(p), _context(p); threaded, loopfunc)

@noinline _makeloop_dynamic!(p::Process, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lt, _context(p); threaded, loopfunc)

function _makeloop!(p::Process, inputs::NamedTuple, lt, base_context; threaded = true, loopfunc::LF = loop) where {LF}
    @atomic p.paused = false
    @atomic p.shouldrun = true
    p.lastresult = nothing

    func = getalgo(p)
    inputs = _validate_runtime_inputs(func, inputs)
    return _makeloop_prepared!(p, func, base_context, lt, inputs; threaded, loopfunc)
end

function _makeloop_prepared!(p::P, func::F, runtime_context::C, lt::LT, inputs::I; threaded::Bool = true, loopfunc::LF = loop, resume::R = Resuming{false}()) where {P<:Process, F, C, LT, I<:NamedTuple, LF, R<:Resuming}
    wait_loop_precompile!(p, func, runtime_context, lt, inputs, resume; loopfunc)
    # `@noinline`: the loop is compiled as its own function with `p` as an argument, so LLVM knows `p` can be read and
    # keeps counters such as `p.tickidx` in a register (inlined into the task closure, it wrote them to memory every repeat).
    if threaded
        p.task = Threads.@spawn @noinline loopfunc(p, func, runtime_context, lt, inputs, resume)
    else
        p.task = @async @noinline loopfunc(p, func, runtime_context, lt, inputs, resume)
    end
    return p
end

function _resume_paused_loop!(p::Process; threaded = true)
    wait(p)
    @atomic p.shouldrun = true
    p.lastresult = nothing

    func = getalgo(p)
    runtime_context = _context(p)
    lt = lifetime(p)
    return _makeloop_prepared!(p, func, runtime_context, lt, (;); threaded, resume = Resuming{true}())
end

makeloop!(p::Process, lt::Lifetime; threaded = true, loopfunc::LF = loop) where {LF} =
    makeloop!(p, (;), lt; threaded, loopfunc)

"""
    reset!(process)

Reset selected `Process` fields without rebuilding its context.

This performs these exact mutations:

- `process.loopidx = 1`
- `process.tickidx = 1`
- `process.paused = false`
- `process.shouldrun = true`
- `process.starttime = nothing`
- `process.endtime = nothing`
- `process.loop_cursor = nothing`: the next run builds a fresh cursor, so every interval counter and resume point
  starts over.

It does not reset counters an algorithm keeps in its own value: a `Package`'s interval counter goes on from where it
was (TODO.md, "Packaging and threaded composites"). It does not change `process.runtime_context`, `process.task`, or
`process.lastresult`. It does not clear or replace values stored in
`context(process)`.
"""
function reset!(p::Process)
    reset_loopidx!(p)
    reset_ticks!(p)
    p.loop_cursor = nothing
    @atomic p.paused = false
    @atomic p.shouldrun = true
    reset_times!(p)
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
