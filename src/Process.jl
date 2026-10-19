export Process, getallocator, getnewallocator, getcontext, getticks


"""
    ProcessCore{F, LT, C}

The mutable part of a `Process`: its plan (`F`, with the registry SA works with, whose `Unique` handles are numbered),
its lifetime, counters, flags and task. The loop gets this object, so its type, and so the compiled loop, is the same for
every new set of `Unique` handles. Every method on `AnyProcess` works on it and on the `Process` around it.
"""
mutable struct ProcessCore{F,LT,C} <: AbstractProcess
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
end

@setterGetter ProcessCore lock shouldrun runtime_context

"""
    Process{F, LT, C, M}

What `Process(...)` returns: the `ProcessCore` (field `core`, all other fields are read and written through to it) and,
as `M`, the `UniqueKeyMap` of its registry (`nothing` without `Unique` handles), so `context(p)[handle]` is inferred
from `p`'s type for a `Unique` handle the user holds. The loop, `init` and the other inferred paths get the core, whose
type has no map: they compile once for every new set of handles.
"""
struct Process{F,LT,C,M} <: AbstractProcess
    core::ProcessCore{F,LT,C}
    keymap::M    # the `UniqueKeyMap` of the registry (no bytes: it is all type data), or `nothing`
end
const AnyProcess = Union{Process, ProcessCore}

"""The `ProcessCore` of a process (itself for a core)."""
@inline getcore(p::Process) = getfield(p, :core)
@inline getcore(p::ProcessCore) = p
@inline Base.getproperty(p::Process, name::Symbol) = getproperty(getcore(p), name)
@inline Base.getproperty(p::Process, name::Symbol, order::Symbol) = getproperty(getcore(p), name, order)
@inline Base.setproperty!(p::Process, name::Symbol, value) = setproperty!(getcore(p), name, value)
@inline Base.setproperty!(p::Process, name::Symbol, value, order::Symbol) = setproperty!(getcore(p), name, value, order)
Base.propertynames(p::Process) = fieldnames(ProcessCore)
# The getters and setters `@setterGetter` made for the core, for the process around it.
for name in fieldnames(ProcessCore)
    name in (:lock, :shouldrun, :runtime_context) && continue
    @eval @inline $name(p::Process) = $name(getcore(p))
    @eval @inline $(Symbol(name, :!))(p::Process, val) = $(Symbol(name, :!))(getcore(p), val)
    @eval @inline $name(p::Process, val) = $name(getcore(p), val)
end
"""
    getloopcursor(p::AnyProcess)

Return the loop cursor stored by a paused run, always as the plan's cursor type `C`.
Throws a `TypeError` when no cursor is stored.
"""
@inline getloopcursor(p::ProcessCore{F,LT,C}) where {F,LT,C} = p.loop_cursor::C
@inline getloopcursor(p::Process) = getloopcursor(getcore(p))

"""
Get value of run of a process, denoting wether it should run or not

Read by the stop checks after every step and after every routine repeat (`_process_breakcondition`). Routine repeats can run for a very long
time, so the check must stay per repeat: checking only once per routine child (or every n repeats) would make a
pause or close wait for the child's remaining repeats and kill interactivity. The check costs a little per repeat
and keeps the compiler from writing a routine's repeats out one after another (perf/README.md shows the cost).
"""
shouldrun(p::AnyProcess) = @atomic :monotonic p.shouldrun   # atomic (no ordering barrier): re-read every step, so pause/close are seen
"""
Set value of run of a process, denoting wether it should run or not
"""
shouldrun(p::AnyProcess, val) = @atomic p.shouldrun = val

# Loop counting
@inline looptick!(p::AnyProcess) = (p.tickidx = p.tickidx + UInt(1))
@inline tick!(p::AnyProcess) = (p.tickidx = p.tickidx + UInt(1))
@inline getticks(p::AnyProcess) = p.tickidx
@inline reset_ticks!(p::AnyProcess) = (p.tickidx = UInt(1))

@inline function _process_state_label(p::AnyProcess)
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

@inline function _process_algo_summary(p::AnyProcess)
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
    # A context the user got from SA carries a `UniqueKeyMap`; the process works with it without (`strip_held_ids`).
    return _finish_process_constructor_with_context(algo, strip_held_ids(context), lifetime, timeout)
end

function _finish_process_constructor_with_context(algo::A, prepared_context::PC, lifetime::LT, timeout) where {A<:AbstractLoopAlgorithm, PC, LT}
    algo = _with_lifecycle(algo, prepared_context, getstoredinits(algo), getstoredoverrides(algo))

    # p = Process(uuid1(), context, td, timeout, nothing, UInt(1), UInt(1), Threads.ReentrantLock(), false, true, nothing, nothing, Arena(), RuntimeListeners(), 0)
    C = typeof(loop_cursor(getplan(algo), Val(true)))
    core = ProcessCore{typeof(algo),typeof(lifetime),C}(uuid1(), algo, lifetime, nothing, nothing, timeout, nothing, UInt(1), UInt(1), Threads.ReentrantLock(), false, true, nothing, nothing, nothing, RuntimeListeners(), 0)

    register_process!(core)
    schedule_loop_precompile!(core, lifetime)
    @DebugMode "Created process with id $(core.id), now preparing data"

    finalizer(remove_process!, core)
    return _wrap_process(core)
end

"""
The `Process` around `core`: its `M` is the `UniqueKeyMap` of its registry (`cached_key_map`), `Nothing` when it has no
`Unique` handles. This is the one untyped call between the typed process and the core: made without compiling anything
per map type (a new `M` for every set of `Unique` handles).
"""
Base.@nospecializeinfer function _wrap_process(@nospecialize(core::ProcessCore))
    ref = registryref(getpersistentcontext(getalgo(core)))
    keymap = ref isa Base.RefValue ? cached_key_map(ref) : nothing
    T = typeof(core).parameters
    return new_instance(Core.apply_type(Process, T[1], T[2], T[3], typeof(keymap)), core, keymap)
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

Base.:(==)(p1::AnyProcess, p2::AnyProcess) = p1.id == p2.id

getalgo(p::P) where {P<:AnyProcess} = p.algo
"""The process's context as SA works with it: its registry stores `Unique` handles numbered (see `context`)."""
function _context(p::P) where {P<:AnyProcess}
    runtime_context = p.runtime_context
    return isnothing(runtime_context) ? getpersistentcontext(getalgo(p)) : runtime_context
end

"""
    context(p)

The process's context, with the `Unique` handles the user holds as keys found from types (`with_held_ids`):
`context(p)[handle]`.
"""
Base.@nospecializeinfer context(@nospecialize(p::AnyProcess)) = with_held_ids(_context(p))

# For a `Process`, the `UniqueKeyMap` is `M`, part of its type, so the context handed to the user is inferred from `p`'s
# type while the typed context is current (as `context` is on a process without `Unique` handles).
function context(p::Process{F,LT,C,M}) where {F,LT,C,M}
    runtime_context = getcore(p).runtime_context
    isnothing(runtime_context) || return with_held_ids(runtime_context, getfield(p, :keymap))
    return _held_context(getpersistentcontext(getalgo(p)), getfield(p, :keymap))
end
@inline _held_context(c::ProcessContext, ::Nothing) = c
@inline _held_context(c::ProcessContext{D, RR}, keymap::M) where {D, RR, M<:UniqueKeyMap} =
    ProcessContext{D, HeldRegistry{RR, M}}(get_subcontexts(c), HeldRegistry{RR, M}(registryref(c)))

"""
Store one live process context in the dynamic runtime slot.

Use this while a `Process` is still resumable, for example after a pause or
before a run with per-call lifetime changes. The stored value may intentionally
deviate from the lifecycle context carried in `p.algo`.
"""
@inline function _store_runtime_context!(p::P, c::C) where {P<:AnyProcess, C}
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
@inline function commit_context!(p::P, c::C) where {P<:AnyProcess, C}
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

function context(p::P, c::C) where {P<:AnyProcess, C}
    p.runtime_context = c
    return c
end

@inline _has_typed_runtime_context(p::P) where {P<:AnyProcess} = isnothing(p.runtime_context)
@inline _typed_runtime_context(p::P) where {P<:AnyProcess} = getpersistentcontext(getalgo(p))

function getcontext(p::AnyProcess)
    return context(p)
end

getcontext(p::AnyProcess, context) = getcontext(p)[context]
set_starttime!(p::AnyProcess) = p.starttime = time_ns()
set_endtime!(p::AnyProcess) = p.endtime = time_ns()
reset_times!(p::AnyProcess) = (p.starttime = nothing; p.endtime = nothing)

runtimelisteners(::Any) = nothing
runtimelisteners(p::AnyProcess) = p.rls

isthreaded(p::AnyProcess) = true

"""
different loopfunction can be passed to the process through overrides
"""
function getloopfunc(p::AnyProcess)
    loop
end




# function Base.finalizer(p::AnyProcess)
#     quit(p)
#     delete!(processlist, p.id)
# end

function runtime(p::AnyProcess)
    @assert !isnothing(p.starttime) "Process has not started"
    return runtime_ns(p) / 1e9
end

function runtime_ns(p::AnyProcess)
    @assert !isnothing(p.starttime) "Process has not started"
    timens = isnothing(p.endtime) ? time_ns() - p.starttime : p.endtime - p.starttime
    return Int(timens)
end
export runtime_ns, runtime

# Exact time the process stopped in hh:mm:ss
function stop_time(p::AnyProcess)
    if isdone(p)
        return Dates.format(Dates.DateTime(p.endtime), "HH:MM:SS")
    else
        return nothing
    end
end

function createfrom!(p1::AnyProcess, p2::AnyProcess)
    p1.algo = p2.algo
    commit_context!(p1, context(p2))
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

@inline lock(p::AnyProcess) = lock(p.lock)
@inline lock(f, p::AnyProcess) = lock(f, p.lock)
@inline unlock(p::AnyProcess) =  unlock(p.lock)

"""
Runs the prepared task of a process on a thread
"""
function makeloop!(p::AnyProcess, inputs::NamedTuple = (;); threaded = true, loopfunc::LF = loop) where {LF}
    if _has_typed_runtime_context(p)
        runtime_context = _typed_runtime_context(p)
        return _makeloop!(p, inputs, lifetime(p), runtime_context; threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs; threaded, loopfunc)
    end
end

function makeloop!(p::AnyProcess, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF}
    if _has_typed_runtime_context(p)
        return _makeloop!(p, inputs, lt, _typed_runtime_context(p); threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs, lt; threaded, loopfunc)
    end
end

@noinline _makeloop_dynamic!(p::AnyProcess, inputs::NamedTuple; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lifetime(p), _context(p); threaded, loopfunc)

@noinline _makeloop_dynamic!(p::AnyProcess, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lt, _context(p); threaded, loopfunc)

function _makeloop!(p::AnyProcess, inputs::NamedTuple, lt, base_context; threaded = true, loopfunc::LF = loop) where {LF}
    @atomic p.paused = false
    @atomic p.shouldrun = true
    p.lastresult = nothing

    func = getalgo(p)
    inputs = _validate_runtime_inputs(func, inputs)
    return _makeloop_prepared!(p, func, base_context, lt, inputs; threaded, loopfunc)
end

function _makeloop_prepared!(p::P, func::F, runtime_context::C, lt::LT, inputs::I; threaded::Bool = true, loopfunc::LF = loop, resume::R = Resuming{false}()) where {P<:AnyProcess, F, C, LT, I<:NamedTuple, LF, R<:Resuming}
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

function _resume_paused_loop!(p::AnyProcess; threaded = true)
    wait(p)
    @atomic p.shouldrun = true
    p.lastresult = nothing

    func = getalgo(p)
    runtime_context = _context(p)
    lt = lifetime(p)
    return _makeloop_prepared!(p, func, runtime_context, lt, (;); threaded, resume = Resuming{true}())
end

makeloop!(p::AnyProcess, lt::Lifetime; threaded = true, loopfunc::LF = loop) where {LF} =
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
- `reset!(getalgo(process))`

It does not change `process.runtime_context`, `process.task`, or
`process.lastresult`. It does not clear or replace values stored in
`context(process)`.
"""
function reset!(p::AnyProcess)
    reset_loopidx!(p)
    reset_ticks!(p)
    p.loop_cursor = nothing
    @atomic p.paused = false
    @atomic p.shouldrun = true
    reset_times!(p)
    algo = getalgo(p)
    reset!(algo)
    return p
end

### LINKING

link_process!(p1::AnyProcess, p2::AnyProcess) = push!(p1.linked_processes, p2)
unlink_process!(p1::AnyProcess, p2::AnyProcess) = filter!(x -> x != p2, p1.linked_processes)

function Base.show(io::IO, p::AnyProcess)
    if !isnothing(p.task) && p.task._isexception
        print(io, "Error in process")
        return display(p.task)
    end
    print(io, _process_state_label(p), " Process(", _process_algo_summary(p), ", lifetime=", lifetime(p), ", loopidx=", loopint(p), ")")

    return nothing
end

function Base.summary(io::IO, p::AnyProcess)
    print(io, "Process(", _process_algo_summary(p), ")")
end

function Base.show(io::IO, ::MIME"text/plain", p::AnyProcess)
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
