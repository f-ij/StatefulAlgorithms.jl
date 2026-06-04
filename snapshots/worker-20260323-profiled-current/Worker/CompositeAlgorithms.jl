export DaggerCompositeAlgorithm, WorkerCompositeAlgorithm

"""
Composite loop algorithm that evaluates child `step!` calls through a routed dependency
DAG of worker tasks.

The constructor API mirrors [`CompositeAlgorithm`](@ref): pass child algorithms, then an
interval tuple, then any states and options.
"""
struct DaggerCompositeAlgorithm{T, Intervals, S, O, ReadOnlyIdxs, id} <: LoopAlgorithm
    funcs::T
    states::S
    options::O
    inc::Base.RefValue{Int}
end

const WorkerCompositeAlgorithm = DaggerCompositeAlgorithm

iscomposite(::Type{<:DaggerCompositeAlgorithm}) = true

DaggerCompositeAlgorithm(args...) = parse_la_input(DaggerCompositeAlgorithm, args...)

function LoopAlgorithm(::Type{DaggerCompositeAlgorithm}, funcs::F, states::Tuple, options::Tuple, intervals; id = nothing) where {F}
    readonlyidxs = _worker_readonly_option_indices(options)
    normalized_options = _worker_normalize_options(options)
    return DaggerCompositeAlgorithm{typeof(funcs), intervals, typeof(states), typeof(normalized_options), readonlyidxs, id}(funcs, states, normalized_options, Ref(1))
end

subalgorithms(dca::DaggerCompositeAlgorithm) = dca.funcs
subalgotypes(dca::DaggerCompositeAlgorithm{FT}) where {FT} = FT.parameters
subalgotypes(::Type{<:DaggerCompositeAlgorithm{FT}}) where {FT} = FT.parameters

getinc(dca::DaggerCompositeAlgorithm) = dca.inc
getoptions(dca::DaggerCompositeAlgorithm) = dca.options

readonlyrouteindices(::Union{DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs}, Type{<:DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs}}}) where {T,I,S,O,ReadOnlyIdxs} = ReadOnlyIdxs

getid(dca::Union{DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs,id}, Type{<:DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs,id}}}) where {T,I,S,O,ReadOnlyIdxs,id} = id
setid(dca::DCA, id = uuid4()) where {DCA<:DaggerCompositeAlgorithm} = setparameter(dca, 6, id)

@inline functypes(::Union{DaggerCompositeAlgorithm{T,I}, Type{<:DaggerCompositeAlgorithm{T,I}}}) where {T,I} = tuple(T.parameters...)
@inline getalgotype(::Union{DaggerCompositeAlgorithm{T,I}, Type{<:DaggerCompositeAlgorithm{T,I}}}, idx) where {T,I} = T.parameters[idx]
@inline numalgos(::Union{DaggerCompositeAlgorithm{T,I}, Type{<:DaggerCompositeAlgorithm{T,I}}}) where {T,I} = length(T.parameters)

@inline function intervals(::Union{DaggerCompositeAlgorithm{T,I}, Type{<:DaggerCompositeAlgorithm{T,I}}}) where {T,I}
    if I isa Tuple
        return I
    else
        return ntuple(_ -> 1, length(T.parameters))
    end
end

@inline intervals(dca::Union{DaggerCompositeAlgorithm, Type{<:DaggerCompositeAlgorithm}}, ::Val{Idx}) where {Idx} = intervals(dca)[Idx]
@inline interval(dca::Union{DaggerCompositeAlgorithm{T,I}, Type{<:DaggerCompositeAlgorithm{T,I}}}, idx) where {T,I} = I[idx]

function setintervals(dca::DCA, new_intervals) where {DCA<:DaggerCompositeAlgorithm}
    @assert length(new_intervals) == length(dca.funcs)
    setparameter(dca, 2, new_intervals)
end

function setinterval(dca::DCA, idx::Int, new_interval) where {DCA<:DaggerCompositeAlgorithm}
    new_intervals = ntuple(i -> i == idx ? new_interval : interval(dca, i), length(dca.funcs))
    setparameter(dca, 2, new_intervals)
end

hasid(dca::Union{DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs,id}, Type{<:DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs,id}}}) where {T,I,S,O,ReadOnlyIdxs,id} = !isnothing(id)
id(dca::Union{DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs,id}, Type{<:DaggerCompositeAlgorithm{T,I,S,O,ReadOnlyIdxs,id}}}) where {T,I,S,O,ReadOnlyIdxs,id} = id

Base.length(dca::DaggerCompositeAlgorithm) = length(dca.funcs)
Base.eachindex(dca::DaggerCompositeAlgorithm) = Base.eachindex(dca.funcs)
getalgo(dca::DaggerCompositeAlgorithm, idx) = dca.funcs[idx]
getalgos(dca::DaggerCompositeAlgorithm) = dca.funcs

"""
Increment the step index for a worker composite algorithm.
"""
@generated function inc!(dca::DaggerCompositeAlgorithm)
    _lcm = lcm(intervals(dca)...)
    return :(dca.inc[] = mod1(dca.inc[] + 1, $_lcm))
end

function reset!(dca::DaggerCompositeAlgorithm)
    dca.inc[] = 1
    reset!.(dca.funcs)
end

multipliers(dca::DaggerCompositeAlgorithm) = 1 ./ intervals(dca)
multipliers(dcaT::Type{<:DaggerCompositeAlgorithm}) = 1 ./ intervals(dcaT)
multiplier(dca::DaggerCompositeAlgorithm, idx) = 1 / interval(dca, idx)

@inline function getvals(dca::DaggerCompositeAlgorithm{FT, Is}) where {FT, Is}
    return Val.(Is)
end

inc(dca::DaggerCompositeAlgorithm) = dca.inc[]
