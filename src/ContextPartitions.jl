#=
How a run's context is partitioned, and which partition a subcontext name refers to.

A run's context has two halves, and each is split into partitions, one per subcontext name:
- the persistent context: one partition per namespace (an algorithm or a `@state`), holding its state;
- the runtime context: the four partitions `_captured_returns`, `_subcontext_returns`, `_declared_locals`, `_inputs`.

Code that has to know where a name lives asks `context_partition(Val(name))` and dispatches on the answer; it never
compares names. Code that only handles the runtime context takes a `RuntimePartition`. A new partition is a new type and
a new method here.

These are internal, like the loop that uses them.
=#

"""One partition of a run's context: a namespace's state in the persistent context, or one of the runtime context's partitions."""
abstract type ContextPartition end

"""A namespace's partition of the persistent context: the state of an algorithm or a `@state`."""
struct NamespacePartition <: ContextPartition end

"""One of the runtime context's four partitions. Its values last one step or the run, never across runs."""
abstract type RuntimePartition <: ContextPartition end

"""Runtime context: what statements (`y = f(x)`) and calls return. One step of the plan node that captures it (see `Scope`). Calls share it as their namespace."""
struct CapturedReturns <: RuntimePartition end
"""Runtime context: per namespace, what its algorithm returns that is not its state. One step of the plan node the algorithm is in."""
struct SubcontextReturns <: RuntimePartition end
"""Runtime context: declared locals (`local x`, `x = nothing`; backend `Local`). The run; kept on a pause."""
struct DeclaredLocals <: RuntimePartition end
"""Runtime context: the inputs a run starts with. The run; read-only; kept on a pause."""
struct Inputs <: RuntimePartition end

"""Which partition of a run's context the subcontext name `name` refers to: a namespace's state, unless `name` is one of the runtime context's partitions."""
context_partition(::Val) = NamespacePartition()
context_partition(::Val{:_captured_returns}) = CapturedReturns()
context_partition(::Val{:_subcontext_returns}) = SubcontextReturns()
context_partition(::Val{:_declared_locals}) = DeclaredLocals()
context_partition(::Val{:_inputs}) = Inputs()

"""The subcontext name a runtime context partition is stored under, e.g. `:_inputs`."""
runtime_partition_name(::CapturedReturns) = :_captured_returns
runtime_partition_name(::SubcontextReturns) = :_subcontext_returns
runtime_partition_name(::DeclaredLocals) = :_declared_locals
runtime_partition_name(::Inputs) = :_inputs

"""Where a value of this partition is read from: the runtime context (`:runtime`), or a namespace's state in the persistent context (`:state`)."""
location_kind(::RuntimePartition) = :runtime
location_kind(::NamespacePartition) = :state
