export Init, Input, Override

abstract type InputInterface end

@inline target_type(::InputInterface) = nothing

struct AllInitTargets end

########################################
########### User Interface #############
########################################

struct Init{Target,NT<:NamedTuple,Ref} <: InputInterface
    vars::NT
    ref::Ref
end

"""
    Init(target, :name => value, ...; kwargs...)

Initialization-time values for one process algorithm or state. These values are
merged before `init` runs and are replayed by `init(la)` when stored on an
initialized loop algorithm.
"""
function Init(target, pairs::Pair{Symbol,<:Any}...; kwargs...)
    nt = (;pairs..., kwargs...)
    Init{_input_target_parameter(target), typeof(nt), typeof(target)}(nt, target)
end

"""
    Init(; name = value, ...)

Initialization-time values for every registered process algorithm or state. Each
target receives these values in its local init context before `init` runs.
"""
function Init(; kwargs...)
    nt = (;kwargs...)
    Init{AllInitTargets, typeof(nt), Nothing}(nt, nothing)
end

Init{Target}(vars::NT) where {Target,NT<:NamedTuple} = Init{Target,NT,Nothing}(vars, nothing)

const Input = Init


"""
Override an internal prepared arg in the context of a target algorithm
"""
struct Override{Target,NT<:NamedTuple,Ref} <: InputInterface
    vars::NT
    ref::Ref
end

function Override(target, pairs::Pair{Symbol,<:Any}...; kwargs...)
    nt = (;pairs..., kwargs...)
    Override{_input_target_parameter(target), typeof(nt), typeof(target)}(nt, target)
end

Override{Target}(vars::NT) where {Target,NT<:NamedTuple} = Override{Target,NT,Nothing}(vars, nothing)

@inline target_type(::Union{Init{Target}, Override{Target}}) where {Target} = Target

@inline _input_target_parameter(target::Symbol) = target
@inline _input_target_parameter(target::Tuple) = map(_input_target_parameter, target)
@inline _input_target_parameter(target::AbstractMatcher) = target
@inline _input_target_parameter(::Type{T}) where {T} = match_by(T)
@inline _input_target_parameter(target) = match_by(target)

########################################
############## Backend #################
########################################

"""
Resolved inputs and overrides are represented by `Init{:target, NT}` and
`Override{:target, NT}` directly.
"""
