export FinalizedAlgorithm, finalstep

# Finalized loop algorithms
#
# `FinalizedAlgorithm` is a transparent LoopAlgorithm wrapper used only at the
# root of a process. It forwards normal loop-algorithm behavior to `inner`, but
# intercepts the result path after loop cleanup so callers can project the final
# cleaned context into the value returned by `fetch(process)`.
#
# Nested finalized wrappers are intentionally rejected by the parser in
# `Setup.jl`: only the outer process has a single final result, while inner loop
# algorithms must continue to behave like ordinary algorithms.

"""
Root-only loop-algorithm wrapper that post-processes the cleaned final context.

`FinalizedAlgorithm` is intended to wrap the outer loop algorithm passed to a
process. When nested inside another loop algorithm constructor, the parser warns
and strips the wrapper so inner context semantics stay ordinary.
"""
struct FinalizedAlgorithm{LA<:AbstractLoopAlgorithm, F} <: AbstractLoopAlgorithm
    inner::LA
    final::F
end

"""
    finalstep(la::LoopAlgorithm, final)

Wrap `la` so `final(cleaned_context)` becomes the process result after the
loop algorithm has finished and its normal `cleanup` step has run.

The wrapper is root-only: pass the returned `FinalizedAlgorithm` directly to a
`Process` or to `resolve`. If it is placed inside another loop-algorithm
constructor, the parser warns and drops the final wrapper because nested loop
algorithms do not own the process-level result.
"""
function finalstep(la::LA, final) where {LA<:AbstractLoopAlgorithm}
    return FinalizedAlgorithm{typeof(la), typeof(final)}(la, final)
end

"""
    finalstep(::Type{<:AbstractLoopAlgorithm}, final)

Reject type-level loop algorithms for finalization.

`finalstep` needs an instantiated loop algorithm so the final wrapper can
preserve the concrete algorithm value and forward all loop operations to it.
"""
function finalstep(::Type{LA}, final) where {LA<:AbstractLoopAlgorithm}
    error("`finalstep` requires an instantiated LoopAlgorithm, not a LoopAlgorithm type.")
end

@inline inneralgorithm(fa::FinalizedAlgorithm) = getfield(fa, :inner)
@inline finalfunction(fa::FinalizedAlgorithm) = getfield(fa, :final)
@inline _finalstep_demands_all_returns(::FinalizedAlgorithm) = Val(true)
@inline _finalstep_demands_all_returns(::Any) = Val(false)

@inline getalgos(fa::FinalizedAlgorithm) = getalgos(inneralgorithm(fa))
@inline getalgo(fa::FinalizedAlgorithm, idx) = getalgo(inneralgorithm(fa), idx)
@inline getstates(fa::FinalizedAlgorithm) = getstates(inneralgorithm(fa))
@inline getoptions(fa::FinalizedAlgorithm) = getoptions(inneralgorithm(fa))
@inline getwiring(fa::FinalizedAlgorithm) = getwiring(inneralgorithm(fa))
@inline getregistry(fa::FinalizedAlgorithm) = getregistry(inneralgorithm(fa))
@inline isresolved(fa::FinalizedAlgorithm) = isresolved(inneralgorithm(fa))
@inline getid(fa::FinalizedAlgorithm) = getid(inneralgorithm(fa))

@inline setoptions(fa::FinalizedAlgorithm, options) = finalstep(setoptions(inneralgorithm(fa), options), finalfunction(fa))
@inline _attach_registry(fa::FinalizedAlgorithm, registry::NameSpaceRegistry) = finalstep(_attach_registry(inneralgorithm(fa), registry), finalfunction(fa))

@inline _with_lifecycle(fa::FinalizedAlgorithm, context, inits, overrides) =
    finalstep(_with_lifecycle(inneralgorithm(fa), context, inits, overrides), finalfunction(fa))
@inline getstoredcontext(fa::FinalizedAlgorithm) = getstoredcontext(inneralgorithm(fa))
@inline getstoredinits(fa::FinalizedAlgorithm) = getstoredinits(inneralgorithm(fa))
@inline getstoredoverrides(fa::FinalizedAlgorithm) = getstoredoverrides(inneralgorithm(fa))

function update_keys(fa::FinalizedAlgorithm, registry::NameSpaceRegistry)
    return finalstep(update_keys(inneralgorithm(fa), registry), finalfunction(fa))
end

@inline Base.length(fa::FinalizedAlgorithm) = length(inneralgorithm(fa))
@inline Base.eachindex(fa::FinalizedAlgorithm) = eachindex(inneralgorithm(fa))
@inline reset!(fa::FinalizedAlgorithm) = reset!(inneralgorithm(fa))
@inline cleanup(fa::FinalizedAlgorithm, context) = cleanup(inneralgorithm(fa), context)

@inline multipliers(fa::FinalizedAlgorithm) = multipliers(inneralgorithm(fa))
@inline intervals(fa::FinalizedAlgorithm) = intervals(inneralgorithm(fa))
@inline intervals(fa::FinalizedAlgorithm, idx) = intervals(inneralgorithm(fa), idx)
@inline interval(fa::FinalizedAlgorithm, idx) = interval(inneralgorithm(fa), idx)
@inline repeats(fa::FinalizedAlgorithm) = repeats(inneralgorithm(fa))
@inline repeats(fa::FinalizedAlgorithm, idx::Int) = repeats(inneralgorithm(fa), idx)
@inline repeats(fa::FinalizedAlgorithm, idx::Val{I}) where {I} = repeats(inneralgorithm(fa), idx)

@inline functypes(::Type{FA}) where {LA, FA<:FinalizedAlgorithm{LA}} = functypes(LA)
@inline functypes(fa::FinalizedAlgorithm) = functypes(inneralgorithm(fa))
@inline algotypes(::Type{FA}) where {LA, FA<:FinalizedAlgorithm{LA}} = algotypes(LA)
@inline algotypes(fa::FinalizedAlgorithm) = algotypes(inneralgorithm(fa))
@inline statetypes(::Type{FA}) where {LA, FA<:FinalizedAlgorithm{LA}} = statetypes(LA)
@inline statetypes(fa::FinalizedAlgorithm) = statetypes(inneralgorithm(fa))
@inline subalgotypes(::Type{FA}) where {LA, FA<:FinalizedAlgorithm{LA}} = subalgotypes(LA)
@inline subalgotypes(fa::FinalizedAlgorithm) = subalgotypes(inneralgorithm(fa))
@inline numalgos(::Type{FA}) where {LA, FA<:FinalizedAlgorithm{LA}} = numalgos(LA)
@inline numalgos(fa::FinalizedAlgorithm) = numalgos(inneralgorithm(fa))
@inline getalgotype(::Type{FA}, idx) where {LA, FA<:FinalizedAlgorithm{LA}} = getalgotype(LA, idx)
@inline getalgotype(fa::FinalizedAlgorithm, idx) = getalgotype(inneralgorithm(fa), idx)

@inline iscomposite(::Type{FA}) where {LA, FA<:FinalizedAlgorithm{LA}} = iscomposite(LA)
@inline iscomposite(fa::FinalizedAlgorithm) = iscomposite(inneralgorithm(fa))

@inline function _loop_final_result(fa::FinalizedAlgorithm, cleaned_context)
    return finalfunction(fa)(cleaned_context)
end

@inline function _loop_final_result(fa::FinalizedAlgorithm, cleaned_context, runtimecontext)
    final = finalfunction(fa)
    return applicable(final, cleaned_context, runtimecontext) ? final(cleaned_context, runtimecontext) : final(cleaned_context)
end

function _strip_nested_finalized_algorithm(algo)
    return algo
end

function _strip_nested_finalized_algorithm(fa::FinalizedAlgorithm)
    @warn "`FinalizedAlgorithm` is root-only. Dropping its final wrapper because it was used inside another LoopAlgorithm."
    return inneralgorithm(fa)
end

function _strip_nested_finalized_algorithm(pair::Pair)
    stripped = _strip_nested_finalized_algorithm(pair.second)
    return stripped === pair.second ? pair : (pair.first => stripped)
end

function Base.show(io::IO, fa::FinalizedAlgorithm)
    println(io, "FinalizedAlgorithm")
    inner_lines = split(sprint(show, inneralgorithm(fa); context = IOContext(io, :limit => get(io, :limit, false), :color => get(io, :color, false))), '\n')
    print(io, "├── inner = ", inner_lines[1])
    for line in Iterators.drop(inner_lines, 1)
        print(io, "\n│   ", line)
    end
    print(io, "\n└── final = ", summary(finalfunction(fa)))
end

function Base.summary(io::IO, fa::FinalizedAlgorithm)
    print(io, "FinalizedAlgorithm(", sprint(summary, inneralgorithm(fa)), ")")
end
