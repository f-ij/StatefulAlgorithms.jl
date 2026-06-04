export ThreadedCompositeAlgorithm, BarrieredCompositeAlgorithm

"""
Composite loop algorithm that evaluates child `step!` calls through threaded dependency
layers.

The constructor API mirrors [`CompositeAlgorithm`](@ref): pass child algorithms, then an
interval tuple, then any states and options.
"""
struct ThreadedCompositeAlgorithm{T, Intervals, S, O, R, id} <: AbstractLoopAlgorithm
    funcs::T
    states::S
    options::O
    inc::Base.RefValue{Int}
    reg::R
end

const BarrieredCompositeAlgorithm = ThreadedCompositeAlgorithm

iscomposite(::Type{TCA}) where {TCA<:ThreadedCompositeAlgorithm} = true

ThreadedCompositeAlgorithm(args...) = parse_la_input(ThreadedCompositeAlgorithm, args...)

function LoopAlgorithm(::Type{ThreadedCompositeAlgorithm}, funcs::F, states::Tuple, options::Tuple, intervals; id = nothing) where {F}
    return ThreadedCompositeAlgorithm{typeof(funcs), intervals, typeof(states), typeof(options), Nothing, id}(funcs, states, options, Ref(1), nothing)
end

function setoptions(tca::ThreadedCompositeAlgorithm{T, Intervals, S, O, R, id}, options) where {T, Intervals, S, O, R, id}
    ThreadedCompositeAlgorithm{T, Intervals, S, typeof(options), R, id}(getalgos(tca), getstates(tca), options, getinc(tca), getregistry(tca))
end

@inline getalgos(tca::ThreadedCompositeAlgorithm) = getfield(tca, :funcs)
@inline getstates(tca::ThreadedCompositeAlgorithm) = getfield(tca, :states)

subalgorithms(tca::ThreadedCompositeAlgorithm) = getalgos(tca)
subalgotypes(tca::ThreadedCompositeAlgorithm{FT}) where {FT} = FT.parameters
subalgotypes(::Type{TCA}) where {FT, TCA<:ThreadedCompositeAlgorithm{FT}} = FT.parameters

getinc(tca::ThreadedCompositeAlgorithm) = getfield(tca, :inc)
getoptions(tca::ThreadedCompositeAlgorithm) = getfield(tca, :options)
@inline getregistry(tca::ThreadedCompositeAlgorithm) = getfield(tca, :reg)
@inline _attach_registry(tca::ThreadedCompositeAlgorithm, registry::NameSpaceRegistry) = setfield(tca, :reg, registry)
@inline isresolved(tca::ThreadedCompositeAlgorithm) = !isnothing(getregistry(tca))

getid(tca::Union{ThreadedCompositeAlgorithm{T,I,S,O,R,id}, Type{<:ThreadedCompositeAlgorithm{T,I,S,O,R,id}}}) where {T,I,S,O,R,id} = id
setid(tca::TCA, id = uuid4()) where {TCA<:ThreadedCompositeAlgorithm} = setparameter(tca, 6, id)

@inline functypes(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}) where {T,I} = tuple(T.parameters...)
@inline getalgotype(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}, idx) where {T,I} = T.parameters[idx]
@inline numalgos(::Union{ThreadedCompositeAlgorithm{T,I}, Type{<:ThreadedCompositeAlgorithm{T,I}}}) where {T,I} = length(T.parameters)

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

hasid(tca::Union{ThreadedCompositeAlgorithm{T,I,S,O,R,id}, Type{<:ThreadedCompositeAlgorithm{T,I,S,O,R,id}}}) where {T,I,S,O,R,id} = !isnothing(id)
id(tca::Union{ThreadedCompositeAlgorithm{T,I,S,O,R,id}, Type{<:ThreadedCompositeAlgorithm{T,I,S,O,R,id}}}) where {T,I,S,O,R,id} = id

Base.length(tca::ThreadedCompositeAlgorithm) = length(getalgos(tca))
Base.eachindex(tca::ThreadedCompositeAlgorithm) = eachindex(getalgos(tca))
getalgo(tca::ThreadedCompositeAlgorithm, idx) = getalgos(tca)[idx]

@generated function inc!(tca::ThreadedCompositeAlgorithm)
    _lcm = lcm(intervals(tca)...)
    return :(getinc(tca)[] = mod1(getinc(tca)[] + 1, $_lcm))
end

function reset!(tca::ThreadedCompositeAlgorithm)
    getinc(tca)[] = 1
    reset!.(getalgos(tca))
end

multipliers(tca::ThreadedCompositeAlgorithm) = map(x -> 1 / getinterval(x), intervals(tca))
multipliers(tcaT::Type{TCA}) where {TCA<:ThreadedCompositeAlgorithm} = map(x -> 1 / getinterval(x), intervals(tcaT))
multiplier(tca::ThreadedCompositeAlgorithm, idx) = 1 / interval(tca, idx)

@inline function getvals(tca::ThreadedCompositeAlgorithm{FT, Is}) where {FT, Is}
    return Val.(Is)
end

inc(tca::ThreadedCompositeAlgorithm) = getinc(tca)[]
