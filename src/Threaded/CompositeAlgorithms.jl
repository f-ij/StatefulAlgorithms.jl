export ThreadedCompositeAlgorithm, BarrieredCompositeAlgorithm

"""
Composite loop algorithm that evaluates child `step!` calls through threaded dependency
layers.

The constructor API mirrors [`CompositeAlgorithm`](@ref): pass child algorithms, then an
interval tuple, then any states and options.
"""
struct ThreadedCompositeAlgorithm{T, Intervals, Namespaces, W, id} <: AbstractPlan
    funcs::T
    intervals
    namespaces::Namespaces
    wiring::W
end

const BarrieredCompositeAlgorithm = ThreadedCompositeAlgorithm

iscomposite(::Type{TCA}) where {TCA<:ThreadedCompositeAlgorithm} = true

ThreadedCompositeAlgorithm(args...) = parse_la_input(ThreadedCompositeAlgorithm, args...)

function LoopAlgorithm(::Type{ThreadedCompositeAlgorithm}, funcs::F, states::Tuple, options::Tuple, intervals; id = nothing) where {F}
    namespaces = ntuple(_ -> Namespace{nothing}(), length(funcs))
    wiring = PlanWiring(_plan_wiring(options), _plan_child_wiring(funcs, options))
    plan = ThreadedCompositeAlgorithm{typeof(funcs), intervals, typeof(namespaces), typeof(wiring), id}(funcs, intervals, namespaces, wiring)
    root_options = _root_loop_options(options)
    return isempty(states) && isempty(root_options) ? plan : LoopAlgorithm(plan; states, options = root_options, id)
end

function setoptions(tca::ThreadedCompositeAlgorithm, options)
    wiring = PlanWiring(_plan_wiring(options), _plan_child_wiring(getalgos(tca), options))
    return setfield(tca, :wiring, wiring)
end

@inline getalgos(tca::ThreadedCompositeAlgorithm) = getfield(tca, :funcs)
@inline getstates(tca::ThreadedCompositeAlgorithm) = ()
@inline getwiring(tca::ThreadedCompositeAlgorithm) = getfield(tca, :wiring)
@inline getoptions(tca::ThreadedCompositeAlgorithm) = _all_plan_wiring(global_wiring(getwiring(tca)), child_wiring(getwiring(tca)))

subalgorithms(tca::ThreadedCompositeAlgorithm) = getalgos(tca)
subalgotypes(tca::ThreadedCompositeAlgorithm{FT}) where {FT} = FT.parameters
subalgotypes(::Type{TCA}) where {FT, TCA<:ThreadedCompositeAlgorithm{FT}} = FT.parameters

getid(tca::Union{ThreadedCompositeAlgorithm{T,I,NS,W,id}, Type{<:ThreadedCompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = id
setid(tca::TCA, id = uuid4()) where {TCA<:ThreadedCompositeAlgorithm} = setparameter(tca, 5, id)

@inline functypes(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}) where {T,I} = tuple(T.parameters...)
@inline getalgotype(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}, idx) where {T,I} = T.parameters[idx]
@inline numalgos(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}) where {T,I} = length(T.parameters)
statetypes(::Union{ThreadedCompositeAlgorithm, Type{<:ThreadedCompositeAlgorithm}}) = ()
algotypes(tca::Union{ThreadedCompositeAlgorithm{FT}, Type{<:ThreadedCompositeAlgorithm{FT}}}) where FT = tuple(FT.parameters...)

@inline function intervals(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}) where {T,I}
    if I isa Tuple
        return I
    else
        return ntuple(_ -> 1, length(T.parameters))
    end
end

@inline intervals(tca::Union{ThreadedCompositeAlgorithm, Type{<:ThreadedCompositeAlgorithm}}, ::Val{Idx}) where {Idx} = intervals(tca)[Idx]
@inline interval(tca::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}, idx) where {T,I} = I[idx]

function setintervals(tca::TCA, new_intervals) where {TCA<:ThreadedCompositeAlgorithm}
    @assert length(new_intervals) == length(getalgos(tca))
    setparameter(tca, 2, new_intervals)
end

function setinterval(tca::TCA, idx::Int, new_interval) where {TCA<:ThreadedCompositeAlgorithm}
    new_intervals = ntuple(i -> i == idx ? new_interval : interval(tca, i), length(getalgos(tca)))
    setparameter(tca, 2, new_intervals)
end

hasid(tca::Union{ThreadedCompositeAlgorithm{T,I,NS,W,id}, Type{<:ThreadedCompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = !isnothing(id)
id(tca::Union{ThreadedCompositeAlgorithm{T,I,NS,W,id}, Type{<:ThreadedCompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = id

Base.length(tca::ThreadedCompositeAlgorithm) = length(getalgos(tca))
Base.eachindex(tca::ThreadedCompositeAlgorithm) = eachindex(getalgos(tca))
getalgo(tca::ThreadedCompositeAlgorithm, idx) = getalgos(tca)[idx]

@generated function inc!(cursor::CompositeLoopCursor, tca::ThreadedCompositeAlgorithm)
    _lcm = lcm(intervals(tca)...)
    return :(getinc(cursor)[] = mod1(getinc(cursor)[] + 1, $_lcm))
end

function reset!(cursor::CompositeLoopCursor, tca::ThreadedCompositeAlgorithm)
    getinc(cursor)[] = 1
    reset!.(getalgos(tca))
end

multipliers(tca::ThreadedCompositeAlgorithm) = map(x -> 1 / getinterval(x), intervals(tca))
multipliers(tcaT::Type{TCA}) where {TCA<:ThreadedCompositeAlgorithm} = map(x -> 1 / getinterval(x), intervals(tcaT))
multiplier(tca::ThreadedCompositeAlgorithm, idx) = 1 / interval(tca, idx)

@inline function getvals(tca::ThreadedCompositeAlgorithm{FT, Is}) where {FT, Is}
    return Val.(Is)
end

inc(cursor::CompositeLoopCursor, ::ThreadedCompositeAlgorithm) = getinc(cursor)[]

@inline plan_child_namespace(tca::ThreadedCompositeAlgorithm, idx::Int) = begin
    name = namesymbol(getfield(getfield(tca, :namespaces), idx))
    isnothing(name) ? trykey(getalgo(tca, idx)) : name
end

@inline _namespace_tuple(::Type{<:ThreadedCompositeAlgorithm{FT,S,NS}}) where {FT,S,NS} = NS

@generated function loop_cursor(plan::P, ::Val{Pausable} = Val(false)) where {P<:ThreadedCompositeAlgorithm, Pausable}
    children = Expr(:tuple, (:(@inline loop_cursor(getfield(@inline(getalgos(plan)), $i), Val($Pausable))) for i in 1:numalgos(P))...)
    return quote
        CompositeLoopCursor(Ref(1), $children)
    end
end
