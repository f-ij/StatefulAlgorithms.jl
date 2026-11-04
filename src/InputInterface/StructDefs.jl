export InitArgs, Only, Override

abstract type InputInterface end

@inline target_type(::InputInterface) = nothing

"""
    get_target(spec)

Return the lifecycle target encoded by an input specification.

Concrete methods are defined immediately after their corresponding lifecycle
input types so generated code observes them in the correct world age.
"""
function get_target end

struct AllInitTargets end

########################################
########### User Interface #############
########################################

"""
    InitArgs(target; name = value, ...)
    InitArgs(target, :name => value, ...)

Values for one algorithm or state that its `init` reads: they are merged into its part of the context before its
`init` runs (`setup`, process construction, `init(plan, context, ...)`, `init!(p, ...)`). Which `init` functions run
is not chosen by `InitArgs`: every one runs, unless an `Only(...)` names the ones that do.
"""
struct InitArgs{Target,NT<:NamedTuple,Ref} <: InputInterface
    vars::NT
    ref::Ref
end

function InitArgs(target, pairs::Pair{Symbol,<:Any}...; kwargs...)
    nt = (;pairs..., kwargs...)
    InitArgs{_input_target_parameter(target), typeof(nt), typeof(target)}(nt, target)
end

"""
    InitArgs(; name = value, ...)

Values for every registered algorithm and state: each receives them in its part of the context before its `init` runs.
"""
function InitArgs(; kwargs...)
    nt = (;kwargs...)
    InitArgs{AllInitTargets, typeof(nt), Nothing}(nt, nothing)
end

InitArgs{Target}(vars::NT) where {Target,NT<:NamedTuple} = InitArgs{Target,NT,Nothing}(vars, nothing)

"""
    InitArgs(A => (; x = 1, y = 2), B => (; z = 3), ...)

The values for several targets in one call: the same as `InitArgs(A; x = 1, y = 2), InitArgs(B; z = 3)`. Returns an
`InitArgsList`, which is passed wherever `InitArgs` is.
"""
InitArgs(first::Pair{<:Any,<:NamedTuple}, rest::Pair{<:Any,<:NamedTuple}...) = _initargs_list((first, rest...))
# Also matches `InitArgs(target, :name => value, ...)` when the first value is a `NamedTuple`; a pair as the first
# argument is never a target, so this is the list form.
InitArgs(first::Pair{<:Any,<:NamedTuple}, rest::Pair{Symbol,<:NamedTuple}...) = _initargs_list((first, rest...))

"""
The `InitArgs` of several targets, made by `InitArgs(A => (; ...), B => (; ...))`. Resolving gives one resolved
`InitArgs` per pair.
"""
struct InitArgsList{T<:Tuple} <: InputInterface
    args::T
end

_initargs_list(pairs::Tuple) = InitArgsList(map(p -> InitArgs(p.first; p.second...), pairs))

"""
    Only(A, B, ...)

Passed to `init(plan, context, ...)` or `init!(p, ...)`: only the `init` of the named algorithms and states runs, the
rest of the context is kept. Without an `Only`, every `init` runs. At most one per call; `InitArgs` for a target it
does not name is an error.
"""
struct Only{Targets, Refs} <: InputInterface
    refs::Refs
end

# The targets as given are kept in `refs` (a type can not go into a type parameter inside a tuple); `Targets` is
# `nothing` until resolving puts the registry keys there.
function Only(targets...)
    isempty(targets) && throw(ArgumentError("Only needs at least one target."))
    return Only{nothing, typeof(targets)}(targets)
end

@inline only_targets(::Union{Only{Targets}, Type{<:Only{Targets}}}) where {Targets} = Targets

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

@inline target_type(::Union{InitArgs{Target}, Override{Target}}) where {Target} = Target

@inline get_target(::Union{InitArgs{Target}, Override{Target}}) where {Target} = Target
@inline get_target(::Type{<:Union{InitArgs{Target}, Override{Target}}}) where {Target} = Target

@inline _input_target_parameter(target::Symbol) = target
@inline _input_target_parameter(target::Tuple) = map(_input_target_parameter, target)
@inline _input_target_parameter(target::AbstractMatcher) = target
@inline _input_target_parameter(::Type{T}) where {T} = match_by(T)
@inline _input_target_parameter(target) = match_by(target)

########################################
############## Backend #################
########################################

"""
Resolved inputs and overrides are represented by `InitArgs{:target, NT}` and
`Override{:target, NT}` directly.
"""
