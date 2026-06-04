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
    name::Symbol
    data::T

    function SubContext{Name,T}(data::T) where {Name,T<:NamedTuple}
        new{Name,T}(Name, data)
    end
end

SubContext(name::Symbol, data::D) where {D<:NamedTuple} = SubContext{name,D}(data)

export inject
#######################
### SUBCONTEXT VIEW ###
#######################

"""
Go from a local variable to the location in the full context
Type can be
    - :local
    - :shared
    - :routed
"""
