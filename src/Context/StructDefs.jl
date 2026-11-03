#######################################
############ PARTITIONS ###############
#######################################
#=
A run's context has two halves, and each is split into partitions, one per subcontext name:
- the persistent context: one `StatePartition{name}` per namespace (an algorithm or a `@state`), holding its state;
- the runtime context: the four partitions `RuntimePartition{:_captured_returns}`, `RuntimePartition{:_subcontext_returns}`,
  `RuntimePartition{:_declared_locals}` and `RuntimePartition{:_inputs}`.

Code dispatches on the partition (`::StatePartition`, `::RuntimePartition`, `::RuntimePartition{:_inputs}`); it never
compares names. A name becomes a partition only through the hook `context_partition` (Hooks.jl), the one place that
knows the four runtime names. A view's locations (`VarLocation`) carry their partition.
=#

"""
    Partition{kind, name}()

The part of a run's context stored under the subcontext name `name`: a namespace's state (`kind = :state`), or one of
the runtime context's partitions (`kind = :runtime`).
"""
struct Partition{kind, name} end

"""A namespace's partition of the persistent context: the state of an algorithm or a `@state`."""
const StatePartition{name} = Partition{:state, name} where {name}

"""
One of the runtime context's four partitions. Its values last one step or the run, never across runs:
- `:_captured_returns`: what statements (`y = f(x)`) and calls return. One step of the plan node that captures it (see
  `Scope`). Calls share it as their namespace.
- `:_subcontext_returns`: per namespace, what its algorithm returns that is not its state. One step of the plan node
  the algorithm is in.
- `:_declared_locals`: declared locals (`local x`, `x = nothing`; backend `Local`). The run; kept on a pause.
- `:_inputs`: the inputs a run starts with. The run; read-only; kept on a pause.
"""
const RuntimePartition{name} = Partition{:runtime, name} where {name}

"""
The subcontext name a partition is stored under, e.g. `:_inputs`. Not specialized: it is compiled once for every
partition, and still folds to a constant where the partition is known.
"""
partition_name(@nospecialize(partition::Partition)) = typeof(partition).parameters[2]::Symbol
partition_name(@nospecialize(P::Type{<:Partition})) = P.parameters[2]::Symbol

#######################################
############# CONTEXT #################
#######################################
"""
Persistent state for a resolved process.

`ProcessContext` stores named subcontexts and the registry needed to resolve
external references. Runtime inputs, loop handles, and transient step returns
live in a separate runtime `ProcessContext` passed explicitly through loop
execution.
"""
struct ProcessContext{D,R} <: AbstractContext
    subcontexts::D
    reg::R

    function ProcessContext{D,R}(subcontexts::D, reg::R) where {D,R}
        new{D,R}(subcontexts, reg)
    end
end

########################
    ### SUBCONTEXT ###
########################

"""
Named local data bucket for one registered process entity.

Route/share metadata deliberately does not live on `SubContext`. Plan routing is
applied through `SubContextView` at step time so context shape stays independent
from execution-plan wiring.
"""
struct SubContext{Name,T<:NamedTuple} <: AbstractSubContext
    data::T   # the name is only in the type: a stored `Symbol` would put 8 bytes between neighbouring subcontexts' data

    function SubContext{Name,T}(data::T) where {Name,T<:NamedTuple}
        new{Name,T}(data)
    end
end

SubContext(name::Symbol, data::D) where {D<:NamedTuple} = SubContext{name,D}(data)
# Name as a type parameter: the result type never depends on constant propagation of a Symbol.
SubContext{Name}(data::D) where {Name,D<:NamedTuple} = SubContext{Name,D}(data)

export inject
#######################
### SUBCONTEXT VIEW ###
#######################
