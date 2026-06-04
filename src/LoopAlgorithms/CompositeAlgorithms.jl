#AlgoTracker
export inc!, nextalgo!, intervals, interval
export CompositeAlgorithm, CompositePlan

"""
Execution plan that steps child algorithms on fixed intervals.

`CompositeAlgorithm` intentionally stores the executable plan: child algorithms
(`funcs`), plan wiring, and the interval cursor (`inc`). Runtime state such as
the registry, root process states, stored context, inputs, and overrides belongs
to the concrete `LoopAlgorithm` wrapper created by `resolve`/`init`.
"""
struct CompositeAlgorithm{T, Intervals, Namespaces, W, id} <: AbstractLoopAlgorithm
    funcs::T
    intervals
    namespaces::Namespaces
    wiring::W
    inc::Base.RefValue{Int} # Runtime interval cursor.
end

const CompositePlan = CompositeAlgorithm

"""Return the per-child execution multiplier implied by interval counts."""
getmultipliers_from_specification_num(::Type{CA}, specification_num) where {CA<:CompositeAlgorithm} = 1 ./(Float64.(specification_num))

CompositeAlgorithm(args...) = parse_la_input(CompositeAlgorithm, args...)

"""
Construct a composite execution plan, wrapping it only when root runtime data exists.

`LocalPlanOption` route/share metadata is split into child-aligned wiring;
plain route/share wiring is stored on the plan. States and other
non-plan options stay on the `LoopAlgorithm` wrapper.
"""
function LoopAlgorithm(::Type{CompositeAlgorithm}, funcs::F, states::Tuple, options::Tuple, intervals; id = nothing) where F
    namespaces = ntuple(_ -> Namespace{nothing}(), length(funcs))
    wiring = PlanWiring(_plan_wiring(options), _plan_child_wiring(funcs, options))
    plan = CompositeAlgorithm{typeof(funcs), intervals, typeof(namespaces), typeof(wiring), id}(funcs, intervals, namespaces, wiring, Ref(1))
    root_options = _root_loop_options(options)
    return isempty(states) && isempty(root_options) ? plan : LoopAlgorithm(plan; states, options = root_options, id)
end

function newfuncs(ca::CompositeAlgorithm, funcs)
    # CompositeAlgorithm{typeof(funcs), intervals(ca), typeof(ca.registry), typeof(ca.options)}(funcs, ca.inc, ca.registry , ca.options)
    setfield(ca, :funcs, funcs)
end

function setoptions(ca::CompositeAlgorithm, options)
    wiring = PlanWiring(_plan_wiring(options), _plan_child_wiring(getalgos(ca), options))
    return setfield(ca, :wiring, wiring)
end

subalgorithms(ca::CompositeAlgorithm) = getalgos(ca)
algotypes(ca::Union{CompositeAlgorithm{FT}, Type{<:CompositeAlgorithm{FT}}}) where FT = FT.parameters
statetypes(ca::Union{CompositeAlgorithm, Type{<:CompositeAlgorithm}}) = ()
subalgotypes(ca::CompositeAlgorithm{FT}) where FT = FT.parameters
subalgotypes(::Type{CA}) where {FT, CA<:CompositeAlgorithm{FT}} = FT.parameters
@inline getstates(ca::CompositeAlgorithm) = ()


getinc(ca::CompositeAlgorithm) = getfield(ca, :inc)
getwiring(ca::CompositeAlgorithm) = getfield(ca, :wiring)
getoptions(ca::CompositeAlgorithm) = _all_plan_wiring(global_wiring(getwiring(ca)), child_wiring(getwiring(ca)))

getid(ca::Union{CompositeAlgorithm{T,I,NS,W,id}, Type{<:CompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = id
setid(ca::CA, id = uuid4()) where {CA<:CompositeAlgorithm} = setparameter(ca, 5, id)

# setname(ca::CA, name::Symbol) where CA <: CompositeAlgorithm = setparameter(ca, 6, name)
# getname(ca::Union{CompositeAlgorithm{T,I,NSR,O,R,id,CustomName}, Type{<:CompositeAlgorithm{T,I,NSR,O,R,id,CustomName}}}) where {T,I,NSR,O,R,id,CustomName} = CustomName

interval(ca::CompositeAlgorithm, idx) = typeof(ca).parameters[2][idx]
interval(::Type{<:CompositeAlgorithm{T,I}}, idx) where {T,I} = I[idx]


###########################################
################ Type Info ###############
###########################################
@inline functypes(ca::Union{CompositeAlgorithm{T,I,NS}, Type{<:CompositeAlgorithm{T,I,NS}}}) where {T,I,NS} = tuple(T.parameters...)
@inline getalgotype(::Union{CompositeAlgorithm{T,I,NS}, Type{<:CompositeAlgorithm{T,I,NS}}}, idx) where {T,I,NS} = T.parameters[idx]
@inline numalgos(::Union{CompositeAlgorithm{T,I,NS}, Type{<:CompositeAlgorithm{T,I,NS}}}) where {T,I,NS} = length(T.parameters)


@inline intervals(ca::CompositeAlgorithm) = typeof(ca).parameters[2]
@inline intervals(::Type{<:CompositeAlgorithm{T,I}}) where {T,I} = I
@inline intervals(ca::Union{CompositeAlgorithm, Type{<:CompositeAlgorithm}}, ::Val{Idx}) where Idx = @inline intervals(ca)[Idx]

get_this_interval(args) = interval(getalgo(args.process), algoidx(args))

function setintervals(ca::C, new_intervals) where {C<:CompositeAlgorithm}
    @assert length(new_intervals) == length(getalgos(ca)) "Length of new intervals must match number of functions in the composite algorithm, but got $(length(new_intervals)) intervals for $(length(getalgos(ca))) functions"
    setparameter(ca, 2, new_intervals)
end

function setinterval(ca::C, idx::Int, new_interval) where {C<:CompositeAlgorithm}
    new_intervals = ntuple(i -> i == idx ? new_interval : interval(ca, i), length(getalgos(ca)))
    setparameter(ca, 2, new_intervals)
end


#######################################
############ Properties ################
########################################
# intervals(ca::C) where {C<:CompositeAlgorithm} = getfield(ca, :intervals)
get_intervals(ca) = intervals(ca)

hasid(ca::Union{CompositeAlgorithm{T,I,NS,W,id}, Type{<:CompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = !isnothing(id)
id(ca::Union{CompositeAlgorithm{T,I,NS,W,id}, Type{<:CompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = id



# getnames(ca::CompositeAlgorithm{T, I, N}) where {T, I, N} = N
Base.length(ca::CompositeAlgorithm) = length(getalgos(ca))
Base.eachindex(ca::CompositeAlgorithm) = eachindex(getalgos(ca))
getalgo(ca::CompositeAlgorithm, idx) = getalgos(ca)[idx]
getalgos(ca::CompositeAlgorithm) = getfield(ca, :funcs)
hasflag(ca::CompositeAlgorithm, flag) = flag in getfield(ca, :flags)
track_algo(ca::CompositeAlgorithm) = hasflag(ca, :trackalgo)
"""
Increment the stepidx for the composite algorithm
"""
@inline @generated function inc!(ca::CA) where CA <: CompositeAlgorithm
    _lcm = lcm(intervals(ca)...)
    return quote
        cainc = getinc(ca)
        cainc[] = mod1(cainc[] + 1, $_lcm)
    end
end

function reset!(ca::CA) where CA <: CompositeAlgorithm
    getinc(ca)[] = 1
    reset!.(getalgos(ca))
end

num_funcs(ca::CompositeAlgorithm{FA}) where FA = fieldcount(FA)

# TODO: WHAT IS THIS
type_instances(ca::CompositeAlgorithm{FT}) where FT = getalgos(ca)
get_funcs(ca::CompositeAlgorithm{FT}) where FT = FT.parameters

# CompositeAlgorithm{FS, Intervals}() where {FS, Intervals} = CompositeAlgorithm{FS, Intervals}(call_all(FS)) 



# repeats(ca::CompositeAlgorithm) = 1 ./ intervals(ca)
# repeats(ca::CompositeAlgorithm, idx) = 1 / interval(ca, idx)
function multipliers(ca::Union{CA, Type{CA}}) where {CA<:CompositeAlgorithm}
    map(x -> 1/getinterval(x), intervals(ca))
end

multiplier(ca::CompositeAlgorithm, idx) = 1 / getinterval(getalgo(ca, idx))

tupletype_to_tuple(t) = (t.parameters...,)
get_intervals(ct::Type{CA}) where {CA<:CompositeAlgorithm} = intervals(ct)

@inline function getvals(ca::CompositeAlgorithm)
    return Val.(intervals(ca))
end

@inline inc(ca::CA) where {CA<:CompositeAlgorithm} = getinc(ca)[]


# CompositeAlgorithm(f, interval::Int, flags...) = CompositeAlgorithm((f,), (interval,), flags...)
