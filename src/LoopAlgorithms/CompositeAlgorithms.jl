#AlgoTracker
export inc!, nextalgo!, intervals, interval
export CompositeAlgorithm, CompositePlan

"""
Execution plan that steps child algorithms on fixed intervals.

`CompositeAlgorithm` stores the block as written: child algorithms (`funcs`),
schedule metadata, namespaces, its route/share wiring (`getwiring`), its own
states (`getstates`: `@state`, `@input`) and its other options (`getoptions`,
such as `RuntimeInputs` and `Redirect`). `resolve` wraps it in a `LoopAlgorithm`
that adds the registry; the context is made by `setup` and kept by the user or a
process, and the interval cursor belongs to the run's `AbstractLoopCursor`.
"""
struct CompositeAlgorithm{T, Intervals, Namespaces, W, id, S, O} <: AbstractPlan
    funcs::T
    intervals::Intervals
    namespaces::Namespaces
    wiring::W
    states::S
    options::O
end

const CompositePlan = CompositeAlgorithm


# The inputs are stripped of `Unique` uuids first (`strip_unique`), so the typed parsing compiles once for new handles.
Base.@nospecializeinfer CompositeAlgorithm(@nospecialize(args...)) = parse_la_input(CompositeAlgorithm, strip_unique(args)...)


function newfuncs(ca::CompositeAlgorithm, funcs)
    # CompositeAlgorithm{typeof(funcs), intervals(ca), typeof(ca.registry), typeof(ca.options)}(funcs, ca.inc, ca.registry , ca.options)
    setfield(ca, :funcs, funcs)
end

"""Rebuild the route/share wiring of `ca` from `wiring` (`Route`s, `Share`s, `LocalPlanOption`s)."""
function setwiring(ca::CompositeAlgorithm, wiring)
    # Declared locals are part of the plan's wiring; rebuilding the routes and shares keeps them.
    wiring = PlanWiring(_build_plan_wiring(wiring), _build_child_wiring(getalgos(ca), wiring), getfield(getwiring(ca), :locals))
    return setfield(ca, :wiring, wiring)
end

algotypes(ca::Union{CompositeAlgorithm{FT}, Type{<:CompositeAlgorithm{FT}}}) where FT = FT.parameters
statetypes(::Union{CompositeAlgorithm{T,I,NS,W,id,S}, Type{<:CompositeAlgorithm{T,I,NS,W,id,S}}}) where {T,I,NS,W,id,S} = S.parameters
subalgotypes(ca::CompositeAlgorithm{FT}) where FT = FT.parameters
subalgotypes(::Type{CA}) where {FT, CA<:CompositeAlgorithm{FT}} = FT.parameters

getid(ca::Union{CompositeAlgorithm{T,I,NS,W,id}, Type{<:CompositeAlgorithm{T,I,NS,W,id}}}) where {T,I,NS,W,id} = id
setid(ca::CA, id = uuid4()) where {CA<:CompositeAlgorithm} = setparameter(ca, 5, id)

# setname(ca::CA, name::Symbol) where CA <: CompositeAlgorithm = setparameter(ca, 6, name)
# getname(ca::Union{CompositeAlgorithm{T,I,NSR,O,R,id,CustomName}, Type{<:CompositeAlgorithm{T,I,NSR,O,R,id,CustomName}}}) where {T,I,NSR,O,R,id,CustomName} = CustomName

interval(ca::CompositeAlgorithm, idx) = getfield(ca, :intervals)[idx]


###########################################
################ Type Info ###############
###########################################
@inline functypes(ca::Union{CompositeAlgorithm{T,I,NS}, Type{<:CompositeAlgorithm{T,I,NS}}}) where {T,I,NS} = tuple(T.parameters...)
@inline getalgotype(::Union{CompositeAlgorithm{T,I,NS}, Type{<:CompositeAlgorithm{T,I,NS}}}, idx) where {T,I,NS} = T.parameters[idx]
@inline numalgos(::Union{CompositeAlgorithm{T,I,NS}, Type{<:CompositeAlgorithm{T,I,NS}}}) where {T,I,NS} = length(T.parameters)


@inline intervals(ca::CompositeAlgorithm) = getfield(ca, :intervals)
@inline intervals(ca::CompositeAlgorithm, ::Val{Idx}) where Idx = @inline intervals(ca)[Idx]
"""The interval of each child as a number, from the type alone (`Interval`'s type holds it)."""
@inline interval_numbers(::Type{<:CompositeAlgorithm{T,I}}) where {T,I} = map(getinterval, fieldtypes(I))

get_this_interval(args) = interval(getalgo(args.process), algoidx(args))

# `setintervals`, `setinterval`: ParameterReplacement.jl.


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
hasflag(ca::CompositeAlgorithm, flag) = flag in getfield(ca, :flags)
track_algo(ca::CompositeAlgorithm) = hasflag(ca, :trackalgo)
"""
Increment the stepidx for the composite algorithm.

The counter cycles as `counter_cycle` (Interval.jl) gives: `1:lcm` without offsets, and past the largest offset
after the first wrap. A compare/select wrap keeps the loop-carried counter off the division path that `mod1` would
put on every tick; with a cycle of one tick the counter never changes.
"""
@inline @generated function inc!(cursor::CompositeLoopCursor, ca::CompositeAlgorithm{T, I}) where {T, I}
    last, restart = counter_cycle(fieldtypes(I))
    last == 1 && return :(nothing)
    return quote
        cainc = getinc(cursor)
        i = cainc[]
        cainc[] = ifelse(i >= $last, $restart, i + 1)
    end
end

num_funcs(ca::CompositeAlgorithm{FA}) where FA = fieldcount(FA)

# TODO: WHAT IS THIS
type_instances(ca::CompositeAlgorithm{FT}) where FT = getalgos(ca)
get_funcs(ca::CompositeAlgorithm{FT}) where FT = FT.parameters

# CompositeAlgorithm{FS, Intervals}() where {FS, Intervals} = CompositeAlgorithm{FS, Intervals}(call_all(FS)) 



# repeats(ca::CompositeAlgorithm) = 1 ./ intervals(ca)
# repeats(ca::CompositeAlgorithm, idx) = 1 / interval(ca, idx)
# On the type, for the tree trackers (Trackers/TreeStructure.jl); a plan value uses `multipliers` (Interface.jl).
multipliers(::Type{CA}) where {CA<:CompositeAlgorithm} = map(n -> 1/n, interval_numbers(CA))

tupletype_to_tuple(t) = (t.parameters...,)

@inline function getvals(ca::CompositeAlgorithm)
    return Val.(intervals(ca))
end

@inline inc(cursor::CompositeLoopCursor) = getinc(cursor)[]


# CompositeAlgorithm(f, interval::Int, flags...) = CompositeAlgorithm((f,), (interval,), flags...)

##########################################
########## Hook extensions ###############
##########################################
# Its children, schedule (`RunIf` entries hold `Var`s), wiring, states and options with their matchers replaced
# (`map_matchers_of_type`, Matching.jl); `namespaces` holds names only.
Base.@nospecializeinfer map_matchers_of_type(M::Type, @nospecialize(plan::CompositeAlgorithm), f) =
    map_matchers_in_fields(M, plan, f, (:funcs, :intervals, :wiring, :states, :options))
