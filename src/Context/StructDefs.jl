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

"""
Where a variable a view sees is stored. The type parameter is the kind of location:
    - :state       the view's namespace's own field (persistent context)
    - :subcontext  a field of another subcontext (a route or share from it)
    - :runtime     a runtime value (declared local, input, captured or subcontext return)
    - :injected    a value given to the view directly
"""
