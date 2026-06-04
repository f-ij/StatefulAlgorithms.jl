export InlineChunkWorker, runchunks!
export beforechunk!, resetexample!, loadexample!, afterexample!, afterchunk!

"""
    InlineChunkWorker(process)

Worker wrapper for running a chunk of examples through one `InlineProcess` task.

The manager starts one task per chunk instead of one task per example. Recipe
callbacks load each example into the inline process context, optionally reset
selected state, and optionally consume the result after each inline run.
"""
mutable struct InlineChunkWorker{IP<:InlineProcess}
    process::IP
    task::Union{Nothing,Task}
    runs::Int
end

"""
    InlineChunkWorker(process::InlineProcess)

Create a chunk worker around an already initialized `InlineProcess`.
"""
function InlineChunkWorker(process::IP) where {IP<:InlineProcess}
    return InlineChunkWorker{IP}(process, nothing, 0)
end

"""
    context(worker::InlineChunkWorker)

Return the context owned by the worker's inline process.
"""
context(worker::W) where {W<:InlineChunkWorker} = context(worker.process)

"""
    beforechunk!(recipe, process, chunk, slot, manager)

Optional chunk-level callback invoked on the worker task before examples are run.
"""
beforechunk!(recipe::Recipe, process::IP, chunk::Chunk, slot::S, manager::M) where {Recipe, IP<:InlineProcess, Chunk, S<:WorkerSlot, M<:ProcessManager} =
    _call_optional_recipe_field(recipe, Val(:beforechunk!), process, chunk, slot, manager)

"""
    resetexample!(recipe, process, example, slot, manager)

Optional per-example callback invoked before `loadexample!`. Use this to reset
only the parts of the inline process context that should not carry across
examples in the same chunk.
"""
resetexample!(recipe::Recipe, process::IP, example::Example, slot::S, manager::M) where {Recipe, IP<:InlineProcess, Example, S<:WorkerSlot, M<:ProcessManager} =
    _call_optional_recipe_field(recipe, Val(:resetexample!), process, example, slot, manager)

"""
    loadexample!(recipe, process, example, slot, manager)

Required per-example callback that writes `example` into the inline process
context before the inline process is run.
"""
loadexample!(recipe::Recipe, process::IP, example::Example, slot::S, manager::M) where {Recipe, IP<:InlineProcess, Example, S<:WorkerSlot, M<:ProcessManager} =
    _call_recipe_field(recipe, Val(:loadexample!), process, example, slot, manager)

"""
    afterexample!(recipe, process, example, result, slot, manager)

Optional per-example callback invoked after `run(process)`. Use this to collect
worker-local output while the chunk is still pinned to the worker task.
"""
afterexample!(recipe::Recipe, process::IP, example::Example, result::Result, slot::S, manager::M) where {Recipe, IP<:InlineProcess, Example, Result, S<:WorkerSlot, M<:ProcessManager} =
    _call_optional_recipe_field(recipe, Val(:afterexample!), process, example, result, slot, manager)

"""
    afterchunk!(recipe, process, chunk, slot, manager)

Optional chunk-level callback invoked after all examples in the chunk have run.
"""
afterchunk!(recipe::Recipe, process::IP, chunk::Chunk, slot::S, manager::M) where {Recipe, IP<:InlineProcess, Chunk, S<:WorkerSlot, M<:ProcessManager} =
    _call_optional_recipe_field(recipe, Val(:afterchunk!), process, chunk, slot, manager)

"""
    _inline_chunk_task_done(worker)

Return whether the worker has no active chunk task.
"""
function _inline_chunk_task_done(worker::W) where {W<:InlineChunkWorker}
    task = worker.task
    return isnothing(task) || istaskdone(task)
end

"""
    _run_inline_chunk!(recipe, worker, chunk, slot, manager)

Run one assigned chunk through `worker.process` on the current task.
"""
function _run_inline_chunk!(recipe::Recipe, worker::W, chunk::Chunk, slot::S, manager::M) where {Recipe, W<:InlineChunkWorker, Chunk, S<:WorkerSlot, M<:ProcessManager}
    process = worker.process
    beforechunk!(recipe, process, chunk, slot, manager)

    # Keep the inline process and its context on this worker task while examples
    # are loaded, run, and consumed.
    for example in chunk
        resetexample!(recipe, process, example, slot, manager)
        loadexample!(recipe, process, example, slot, manager)
        result = run(process)
        afterexample!(recipe, process, example, result, slot, manager)
        worker.runs += 1
    end

    afterchunk!(recipe, process, chunk, slot, manager)
    return worker
end

"""
    _run_inline_chunk_now!(manager, slot, chunk)

Run a chunk worker immediately in the current task. Threaded manager schedules
use this so chunk setup, every example run, and chunk cleanup stay on the same
threaded iteration.
"""
function _run_inline_chunk_now!(manager::M, slot::S, chunk::Chunk) where {M<:ProcessManager, S<:WorkerSlot{<:InlineChunkWorker}, Chunk}
    worker = slot.worker
    _inline_chunk_task_done(worker) || throw(ArgumentError("InlineChunkWorker is already running a chunk."))
    worker.task = nothing
    return _run_inline_chunk!(manager.recipe, worker, chunk, slot, manager)
end

"""
    _start_inline_chunk_worker!(manager, slot, chunk)

Start one chunk on an `InlineChunkWorker` using one spawned task for the full
chunk.
"""
function _start_inline_chunk_worker!(manager::M, slot::S, chunk::Chunk) where {M<:ProcessManager, S<:WorkerSlot{<:InlineChunkWorker}, Chunk}
    worker = slot.worker
    _inline_chunk_task_done(worker) || throw(ArgumentError("InlineChunkWorker is already running a chunk."))
    worker.task = Threads.@spawn _run_inline_chunk!(manager.recipe, worker, chunk, slot, manager)
    return worker
end

"""
    _start_slot!(manager, slot::WorkerSlot{<:InlineChunkWorker}, chunk)

Start one chunk worker slot. A recipe `start!` callback can still replace the
default chunk runner.
"""
function _start_slot!(manager::M, slot::S, chunk) where {M<:ProcessManager, S<:WorkerSlot{<:InlineChunkWorker}}
    result = start!(manager.recipe, slot, chunk, manager)
    _is_no_recipe_callback(result) || return result
    return _start_inline_chunk_worker!(manager, slot, chunk)
end

"""
    _start_slot_inline!(manager, slot::WorkerSlot{<:InlineChunkWorker}, chunk)

Start a chunk worker inside a threaded manager iteration. A recipe `start!`
callback can still replace the default chunk runner.
"""
function _start_slot_inline!(manager::M, slot::S, chunk) where {M<:ProcessManager, S<:WorkerSlot{<:InlineChunkWorker}}
    result = start!(manager.recipe, slot, chunk, manager)
    _is_no_recipe_callback(result) || return result
    return _run_inline_chunk_now!(manager, slot, chunk)
end

"""
    _worker_isdone(worker::InlineChunkWorker)

Return whether the current chunk task has finished.
"""
function _worker_isdone(worker::W) where {W<:InlineChunkWorker}
    return _inline_chunk_task_done(worker)
end

"""
    _finalize_worker!(worker::InlineChunkWorker)

Wait for a chunk task, propagate task errors, and make the worker reusable.
"""
function _finalize_worker!(worker::W) where {W<:InlineChunkWorker}
    task = worker.task
    if !isnothing(task)
        fetch(task)
        worker.task = nothing
    end
    return worker
end

"""
    _close_worker!(worker::InlineChunkWorker)

Close a chunk worker by waiting for any active chunk task to finish.
"""
function _close_worker!(worker::W) where {W<:InlineChunkWorker}
    task = worker.task
    if !isnothing(task)
        fetch(task)
        worker.task = nothing
    end
    return worker
end

"""
    _chunk_buffer(jobs)

Create a chunk buffer using the iterable's declared element type when available.
"""
function _chunk_buffer(jobs::J) where {J}
    if Base.IteratorEltype(J) === Base.HasEltype()
        return Vector{eltype(jobs)}()
    end
    return Any[]
end

"""
    _chunked_jobs(jobs, chunksize)

Collect an iterable into chunk vectors suitable for threaded chunk scheduling.
"""
function _chunked_jobs(jobs::Jobs, chunksize::Integer) where {Jobs}
    chunksize > 0 || throw(ArgumentError("`chunksize` must be positive."))
    chunk = _chunk_buffer(jobs)
    chunks = Vector{typeof(chunk)}()
    sizehint!(chunk, Int(chunksize))

    for job in jobs
        push!(chunk, job)
        if length(chunk) >= chunksize
            push!(chunks, chunk)
            chunk = similar(chunk, 0)
            sizehint!(chunk, Int(chunksize))
        end
    end

    !isempty(chunk) && push!(chunks, chunk)
    return chunks
end

"""
    runchunks!(manager, jobs; chunksize)

Dispatch `jobs` as vector chunks. Each chunk is one manager job, so an
`InlineChunkWorker` processes many examples inside one spawned task.
"""
function runchunks!(manager::M, jobs::Jobs; chunksize::Integer) where {M<:ProcessManager, Jobs}
    chunksize > 0 || throw(ArgumentError("`chunksize` must be positive."))
    chunk = _chunk_buffer(jobs)
    sizehint!(chunk, Int(chunksize))

    for job in jobs
        push!(chunk, job)
        if length(chunk) >= chunksize
            dispatch!(manager, chunk)
            poll!(manager)
            chunk = similar(chunk, 0)
            sizehint!(chunk, Int(chunksize))
        end
    end

    if !isempty(chunk)
        dispatch!(manager, chunk)
        poll!(manager)
    end

    drain!(manager)
    return manager
end

"""
    runchunks!(manager, jobs, schedule; chunksize)

Dispatch `jobs` as chunks and run those chunks through `runthreaded!` with the
given thread schedule. Each chunk is one manager job, and `InlineChunkWorker`
slots execute their examples inline on the owning threaded iteration.
"""
function runchunks!(manager::M, jobs::Jobs, schedule::S; chunksize::Integer) where {M<:ProcessManager, Jobs, S<:ThreadsType}
    chunks = _chunked_jobs(jobs, chunksize)
    isempty(chunks) && return manager
    return runthreaded!(manager, chunks, schedule)
end
