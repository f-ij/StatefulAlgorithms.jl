# On-demand manager worker lifecycle.
#
# This mode is separate from the reusable-worker manager path. Slots are created
# without workers, and each dispatched job constructs the worker that will run it.

export OnDemandWorkers

"""
    OnDemandWorkers(; destroy_after_finalize = true)

Construct a fresh worker for each job by calling
`makeworker(idx, manager, job)`.

When `destroy_after_finalize` is true, the worker is cleaned up after
`consume!` and `release!`. Recipe `destroyworker!` gets first chance to clean
up; if it is missing, the manager tries recipe `close!`, then the default worker
close behavior.
"""
struct OnDemandWorkers{DestroyAfterFinalize} <: WorkerLifecycle
    function OnDemandWorkers{DestroyAfterFinalize}() where {DestroyAfterFinalize}
        DestroyAfterFinalize isa Bool || throw(ArgumentError("`DestroyAfterFinalize` must be `true` or `false`."))
        return new{DestroyAfterFinalize}()
    end
end

OnDemandWorkers(; destroy_after_finalize::Bool = true) =
    OnDemandWorkers{destroy_after_finalize}()

"""
    destroyworker!(recipe, slot, job, manager)

Optional cleanup callback for `OnDemandWorkers`.
"""
destroyworker!(recipe, slot, job, manager) =
    _call_optional_recipe_field(recipe, Val(:destroyworker!), slot, job, manager)

"""
    _manager_worker_values(..., lifecycle::OnDemandWorkers)

Create empty worker placeholders. Actual workers are built from job data during
dispatch.
"""
function _manager_worker_values(
    recipe,
    nworkers::Integer,
    build_manager,
    worker_init::WIM,
    worker_init_data,
    workers,
    ::OnDemandWorkers,
) where {WIM<:WorkerInitMode}
    isnothing(workers) || throw(ArgumentError("`OnDemandWorkers` constructs workers from jobs; pass `nworkers`, not `workers`."))
    isnothing(worker_init_data) || throw(ArgumentError("`worker_init_data` is not used with `OnDemandWorkers`; put job-specific data in the job."))

    return ntuple(_ -> nothing, Int(nworkers))
end

"""
    _manager_slot_worker_type(worker_type, lifecycle::OnDemandWorkers)

Build the slot worker field type for empty on-demand slots.
"""
_manager_slot_worker_type(::Nothing, ::OnDemandWorkers) = Any
_manager_slot_worker_type(::Type{W}, ::OnDemandWorkers) where {W} = Union{Nothing, W}
_manager_slot_worker_type(worker_type, ::OnDemandWorkers) =
    throw(ArgumentError("`worker_type` must be a type or `nothing`, got $(typeof(worker_type))."))

"""
    _manager_worker_names(..., lifecycle::OnDemandWorkers)

Create placeholder names for empty on-demand slots. The real name is installed
from the job when the worker is constructed.
"""
function _manager_worker_names(recipe, nworkers::Integer, build_manager, workers, ::OnDemandWorkers)
    return ntuple(idx -> Symbol(:worker_, idx), Int(nworkers))
end

"""
    _close_worker!(worker::Nothing)

No-op close for empty on-demand worker slots.
"""
_close_worker!(worker::Nothing) = worker

"""
    _clear_on_demand_worker!(slot)

Clear a destroyed on-demand worker when the slot type can hold `nothing`.
"""
function _clear_on_demand_worker!(slot::WorkerSlot{W}) where {W}
    nothing isa W && (slot.worker = nothing)
    return slot
end

"""
    _make_on_demand_worker(recipe, slot, job, manager)

Construct the worker for one job.
"""
function _make_on_demand_worker(recipe, slot::S, job, manager::M) where {S<:WorkerSlot, M<:ProcessManager}
    return makeworker(recipe, slot.idx, manager, job)
end

"""
    _assign_job_worker!(manager, slot, job, lifecycle::OnDemandWorkers)

Install the worker produced from this job.
"""
function _assign_job_worker!(manager::M, slot::WorkerSlot{W}, job, ::OnDemandWorkers{D}) where {M<:ProcessManager, W, D}
    worker = _make_on_demand_worker(manager.recipe, slot, job, manager)
    worker isa W || throw(ArgumentError("Recipe callback `makeworker(idx, manager, job)` returned $(typeof(worker)), which cannot be stored in a slot typed for $W."))
    _set_slot_name!(slot, workername(manager.recipe, slot.idx, manager, job))
    slot.worker = worker
    return slot
end

"""
    _destroy_finished_job_worker!(manager, slot, job, ::OnDemandWorkers{false})

Keep the finished on-demand worker in the slot for inspection or later manual
cleanup.
"""
function _destroy_finished_job_worker!(manager::M, slot::S, job, ::OnDemandWorkers{false}) where {M<:ProcessManager, S<:WorkerSlot}
    return slot
end

"""
    _destroy_finished_job_worker!(manager, slot, job, ::OnDemandWorkers{true})

Clean up a finished on-demand worker after result-reading hooks complete.
"""
function _destroy_finished_job_worker!(manager::M, slot::S, job, ::OnDemandWorkers{true}) where {M<:ProcessManager, S<:WorkerSlot}
    result = destroyworker!(manager.recipe, slot, job, manager)
    if _is_no_recipe_callback(result)
        close_result = close!(manager.recipe, slot, manager)
        _is_no_recipe_callback(close_result) && _close_worker!(slot.worker)
    end

    _clear_on_demand_worker!(slot)
    return slot
end
