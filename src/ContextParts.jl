#=
The parts of a run's context, and which part a subcontext name refers to.

A run holds the stored context (one subcontext per namespace: an algorithm's or state's state) and a runtime context
with the parts below. Code that has to know where a name lives asks `context_part(Val(name))` and dispatches on the
answer; it never compares names. A new part is a new type and a new method here.

These are internal, like the loop that uses them.
=#

abstract type ContextPart end

"""A namespace of the stored context: an algorithm's or state's state. Persistent."""
struct Stored <: ContextPart end
"""What statements (`y = f(x)`) and calls return. One step. Calls share it as their namespace."""
struct DeclaredOutputs <: ContextPart end
"""Per namespace, what its algorithm returns that is not its state. One step."""
struct SubcontextOutputs <: ContextPart end
"""Declared locals (`local x`, `x = nothing`; backend `Local`). The run; kept on a pause."""
struct DeclaredLocals <: ContextPart end
"""The inputs a run starts with. The run; read-only; kept on a pause."""
struct Inputs <: ContextPart end

"""The part of a run's context that the subcontext name `name` refers to: a namespace of the stored context unless it is one of the runtime parts."""
context_part(::Val) = Stored()
context_part(::Val{:_declared_outputs}) = DeclaredOutputs()
context_part(::Val{:_subcontext_outputs}) = SubcontextOutputs()
context_part(::Val{:_declared_locals}) = DeclaredLocals()
context_part(::Val{:_inputs}) = Inputs()

"""The subcontext name a runtime part is stored under."""
part_name(::DeclaredOutputs) = :_declared_outputs
part_name(::SubcontextOutputs) = :_subcontext_outputs
part_name(::DeclaredLocals) = :_declared_locals
part_name(::Inputs) = :_inputs

"""Where a value of this part is read from: the runtime context (`:runtime`), or the stored context (`:subcontext`)."""
location_kind(::ContextPart) = :runtime
location_kind(::Stored) = :subcontext

"""
The target of the routes that make declared locals visible to a view: the view itself, since such a binding has no
target algorithm (see `routes(::PlanWiringView)`). A view tells these routes from its own wires by this target.
"""
struct LocalScope <: AbstractScope end
