# Display methods for ProcessManager and WorkerSlot diagnostics.

"""
Return a short status label for a manager slot.
"""
function _slot_status_label(slot::S) where {S<:WorkerSlot}
    if slot.active
        return :active
    elseif !isnothing(slot.error)
        return :error
    elseif isnothing(slot.worker)
        return :empty
    else
        return :idle
    end
end

"""
Return a compact label for values shown in manager summaries.
"""
function _manager_value_label(value::V) where {V}
    isnothing(value) && return "nothing"
    return sprint(summary, value)
end

"""
Return the number of manager slots currently marked active.
"""
function _manager_active_count(manager::M) where {M<:ProcessManager}
    return count(slot -> slot.active, manager.slots)
end

"""
Print one manager slot as a compact diagnostic line.
"""
function _show_manager_slot_line(io::IO, slot::S; prefix::String = "") where {S<:WorkerSlot}
    print(
        io,
        prefix,
        "[",
        slot.idx,
        "] ",
        repr(slot.name),
        " ",
        _slot_status_label(slot),
        " runs=",
        slot.runs,
        " worker=",
        _manager_value_label(slot.worker),
    )
    !isnothing(slot.job) && print(io, " job=", _manager_value_label(slot.job))
    !isnothing(slot.result) && print(io, " result=", _manager_value_label(slot.result))
    !isnothing(slot.error) && print(io, " error=", _manager_value_label(slot.error))
    return nothing
end

"""
Show a compact one-line `WorkerSlot` representation.
"""
function Base.show(io::IO, slot::S) where {S<:WorkerSlot}
    print(io, "WorkerSlot(")
    _show_manager_slot_line(io, slot)
    print(io, ")")
    return nothing
end

"""
Show a short `WorkerSlot` summary.
"""
function Base.summary(io::IO, slot::S) where {S<:WorkerSlot}
    print(io, "WorkerSlot(", slot.idx, ", ", _slot_status_label(slot), ")")
    return nothing
end

"""
Show a detailed multiline `WorkerSlot` representation.
"""
function Base.show(io::IO, ::MIME"text/plain", slot::S) where {S<:WorkerSlot}
    println(io, "WorkerSlot")
    println(io, "├── idx = ", slot.idx)
    println(io, "├── name = ", repr(slot.name))
    println(io, "├── status = ", _slot_status_label(slot))
    println(io, "├── runs = ", slot.runs)
    println(io, "├── worker = ", _manager_value_label(slot.worker))
    println(io, "├── job = ", _manager_value_label(slot.job))
    println(io, "├── result = ", _manager_value_label(slot.result))
    print(io, "└── error = ", _manager_value_label(slot.error))
    return nothing
end

"""
Show a compact one-line `ProcessManager` representation.
"""
function Base.show(io::IO, manager::M) where {M<:ProcessManager}
    active = _manager_active_count(manager)
    print(
        io,
        "ProcessManager(",
        manager.closed ? "closed" : "open",
        ", workers=",
        length(manager.slots),
        ", active=",
        active,
        ", completions=",
        manager.completions,
        ", errors=",
        length(manager.errors),
        ")",
    )
    return nothing
end

"""
Show a short `ProcessManager` summary.
"""
function Base.summary(io::IO, manager::M) where {M<:ProcessManager}
    print(io, "ProcessManager(", length(manager.slots), " workers, ", manager.closed ? "closed" : "open", ")")
    return nothing
end

"""
Show a detailed multiline `ProcessManager` representation.
"""
function Base.show(io::IO, ::MIME"text/plain", manager::M) where {M<:ProcessManager}
    active = _manager_active_count(manager)
    println(io, "ProcessManager")
    println(io, "├── status = ", manager.closed ? :closed : :open)
    println(io, "├── workers = ", length(manager.slots), " (active=", active, ", idle=", length(manager.slots) - active, ")")
    println(io, "├── lifecycle = ", typeof(manager.worker_lifecycle))
    println(io, "├── flush_policy = ", manager.flush_policy)
    println(
        io,
        "├── progress = dispatched=",
        manager.dispatched,
        ", completions=",
        manager.completions,
        ", since_flush=",
        manager.completions_since_flush,
    )
    println(io, "├── errors = ", length(manager.errors))
    print(io, "└── slots")
    for slot in manager.slots
        print(io, "\n    ")
        _show_manager_slot_line(io, slot)
    end
    return nothing
end
