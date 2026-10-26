export ThreadedCompositeAlgorithm, BarrieredCompositeAlgorithm

"""
Composite loop algorithm that evaluates child `step!` calls through threaded dependency
layers.

The constructor API mirrors [`CompositeAlgorithm`](@ref): pass child algorithms, then an
interval tuple, then any states and options.
"""
struct ThreadedCompositeAlgorithm{T, Intervals, Namespaces, W, id, S, O} <: AbstractPlan
    funcs::T
    intervals::Intervals
    namespaces::Namespaces
    wiring::W
    states::S
    options::O
end

const BarrieredCompositeAlgorithm = ThreadedCompositeAlgorithm

iscomposite(::Type{TCA}) where {TCA<:ThreadedCompositeAlgorithm} = true

ThreadedCompositeAlgorithm(args...) = parse_la_input(ThreadedCompositeAlgorithm, args...)


"""Rebuild the route/share wiring of `tca` from `wiring` (`Route`s, `Share`s, `LocalPlanOption`s)."""
function setwiring(tca::ThreadedCompositeAlgorithm, wiring)
    wiring = PlanWiring(_build_plan_wiring(wiring), _build_child_wiring(getalgos(tca), wiring))
    return setfield(tca, :wiring, wiring)
end

statetypes(::Union{ThreadedCompositeAlgorithm{T,I,NS,W,id,S}, Type{<:ThreadedCompositeAlgorithm{T,I,NS,W,id,S}}}) where {T,I,NS,W,id,S} = S.parameters

subalgotypes(tca::ThreadedCompositeAlgorithm{FT}) where {FT} = FT.parameters
subalgotypes(::Type{TCA}) where {FT, TCA<:ThreadedCompositeAlgorithm{FT}} = FT.parameters

getid(tca::Union{ThreadedCompositeAlgorithm{T,I,NS,W,id}, Type{<:ThreadedCompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = id
setid(tca::TCA, id = uuid4()) where {TCA<:ThreadedCompositeAlgorithm} = setparameter(tca, 5, id)

@inline functypes(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}) where {T,I} = tuple(T.parameters...)
@inline getalgotype(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}, idx) where {T,I} = T.parameters[idx]
@inline numalgos(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}) where {T,I} = length(T.parameters)
statetypes(::Union{ThreadedCompositeAlgorithm, Type{<:ThreadedCompositeAlgorithm}}) = ()
algotypes(tca::Union{ThreadedCompositeAlgorithm{FT}, Type{<:ThreadedCompositeAlgorithm{FT}}}) where FT = tuple(FT.parameters...)

@inline intervals(tca::ThreadedCompositeAlgorithm) = getfield(tca, :intervals)
@inline intervals(tca::ThreadedCompositeAlgorithm, ::Val{Idx}) where {Idx} = intervals(tca)[Idx]
@inline interval(tca::ThreadedCompositeAlgorithm, idx) = intervals(tca)[idx]
"""The interval of each child as a number, from the type alone (`Interval`'s type holds it)."""
@inline interval_numbers(::Type{<:ThreadedCompositeAlgorithm{T,I}}) where {T,I} = map(getinterval, fieldtypes(I))

# Through `setschedule` (LoopAlgorithms/ParameterReplacement.jl).
function setintervals(tca::ThreadedCompositeAlgorithm, new_intervals)
    @assert length(new_intervals) == length(getalgos(tca))
    return setschedule(tca, Tuple(new_intervals))
end
setinterval(tca::ThreadedCompositeAlgorithm, idx::Int, new_interval) =
    setschedule(tca, Base.setindex(getschedule(tca), _as_interval(new_interval), idx))

hasid(tca::Union{ThreadedCompositeAlgorithm{T,I,NS,W,id}, Type{<:ThreadedCompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = !isnothing(id)
id(tca::Union{ThreadedCompositeAlgorithm{T,I,NS,W,id}, Type{<:ThreadedCompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = id

Base.length(tca::ThreadedCompositeAlgorithm) = length(getalgos(tca))
Base.eachindex(tca::ThreadedCompositeAlgorithm) = eachindex(getalgos(tca))

@generated function inc!(cursor::CompositeLoopCursor, tca::ThreadedCompositeAlgorithm)
    _lcm = lcm(interval_numbers(tca)...)
    # TODO: Use the compare/select wrap from the core inc! (LoopAlgorithms/CompositeAlgorithms.jl); mod1 costs ~3 ns per tick.
    return :(getinc(cursor)[] = mod1(getinc(cursor)[] + 1, $_lcm))
end

multipliers(::Type{TCA}) where {TCA<:ThreadedCompositeAlgorithm} = map(n -> 1 / n, interval_numbers(TCA))

@inline getvals(tca::ThreadedCompositeAlgorithm) = Val.(intervals(tca))

inc(cursor::CompositeLoopCursor, ::ThreadedCompositeAlgorithm) = getinc(cursor)[]

"""Return the resolved or explicitly carried namespace for one threaded child."""
@inline plan_child_namespace(tca::TCA, idx::Int) where {TCA<:ThreadedCompositeAlgorithm} = begin
    name = namesymbol(getfield(getfield(tca, :namespaces), idx))
    isnothing(name) || return name

    # Unresolved/structural plan children may still carry an explicit key.
    fallback = _entity_key(getalgo(tca, idx))
    return fallback == Symbol() ? nothing : fallback
end

@inline _namespace_tuple(::Type{<:ThreadedCompositeAlgorithm{FT,S,NS}}) where {FT,S,NS} = NS

@generated function loop_cursor(plan::P, ::Val{Pausable} = Val(false)) where {P<:ThreadedCompositeAlgorithm, Pausable}
    children = Expr(:tuple, (:(@inline loop_cursor(getfield(@inline(getalgos(plan)), $i), Val($Pausable))) for i in 1:numalgos(P))...)
    return quote
        CompositeLoopCursor(Ref(1), $children)
    end
end
