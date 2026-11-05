export FinalizedAlgorithm, finalstep

# Finalized loop algorithms
#
# `FinalizedAlgorithm` is a transparent LoopAlgorithm wrapper used only at the
# root of a process. It forwards normal loop-algorithm behavior to `inner`, but
# intercepts the result path after loop cleanup so callers can project the final
# cleaned context into the value returned by `fetch(process)`.
#
# Nested finalized wrappers are intentionally rejected by the parser in
# `ConstructorCommon.jl`: only the outer process has a single final result, while inner loop
# algorithms must continue to behave like ordinary algorithms.
#
# Its method of the hook it extends (`loop_final_result`, Hooks.jl) is in the hook-extensions section at the end.

"""
Root-only loop-algorithm wrapper that post-processes the cleaned final context.

`FinalizedAlgorithm` is intended to wrap the outer loop algorithm passed to a
process. When nested inside another loop algorithm constructor, the parser warns
and strips the wrapper so inner context semantics stay ordinary.
"""
struct FinalizedAlgorithm{LA<:LoopSpec, F} <: AbstractLoopAlgorithm
    inner::LA
    final::F
end

"""
    finalstep(la::LoopAlgorithm, final)

Wrap `la` so `final(context)` becomes the process result after the loop
algorithm has finished and its normal `cleanup` step has run. `context` is the
final context (`final_context`): the cleaned persistent context with the run's
inputs and declared locals.

The wrapper is root-only: pass the returned `FinalizedAlgorithm` directly to a
`Process` or to `resolve`. If it is placed inside another loop-algorithm
constructor, the parser warns and drops the final wrapper because nested loop
algorithms do not own the process-level result.
"""
function finalstep(la::LA, final) where {LA<:LoopSpec}
    return FinalizedAlgorithm{typeof(la), typeof(final)}(la, final)
end

"""
    finalstep(::Type{<:AbstractLoopAlgorithm}, final)

Reject type-level loop algorithms for finalization.

`finalstep` needs an instantiated loop algorithm so the final wrapper can
preserve the concrete algorithm value and forward all loop operations to it.
"""
function finalstep(::Type{LA}, final) where {LA<:LoopSpec}
    error("`finalstep` requires an instantiated LoopAlgorithm, not a LoopAlgorithm type.")
end

@inline inneralgorithm(fa::FinalizedAlgorithm) = getfield(fa, :inner)
@inline finalfunction(fa::FinalizedAlgorithm) = getfield(fa, :final)

@inline getalgos(fa::FinalizedAlgorithm) = getalgos(inneralgorithm(fa))
@inline getalgo(fa::FinalizedAlgorithm, idx) = getalgo(inneralgorithm(fa), idx)
@inline getstates(fa::FinalizedAlgorithm) = getstates(inneralgorithm(fa))
@inline _collect_root_options(fa::FinalizedAlgorithm) = _collect_root_options(inneralgorithm(fa))
@inline collect_wiring(fa::FinalizedAlgorithm) = collect_wiring(inneralgorithm(fa))
@inline _collect_tree_wiring(fa::FinalizedAlgorithm) = _collect_tree_wiring(inneralgorithm(fa))
@inline getoptions(fa::FinalizedAlgorithm) = getoptions(inneralgorithm(fa))
@inline getwiring(fa::FinalizedAlgorithm) = getwiring(inneralgorithm(fa))
@inline getregistry(fa::FinalizedAlgorithm) = getregistry(inneralgorithm(fa))
@inline isresolved(::Union{FinalizedAlgorithm{LA}, Type{<:FinalizedAlgorithm{LA}}}) where {LA<:LoopSpec} = isresolved(LA)
@inline getid(fa::FinalizedAlgorithm) = getid(inneralgorithm(fa))

@inline setoptions(fa::FinalizedAlgorithm, options) = finalstep(setoptions(inneralgorithm(fa), options), finalfunction(fa))
@inline setwiring(fa::FinalizedAlgorithm, wiring) = finalstep(setwiring(inneralgorithm(fa), wiring), finalfunction(fa))
@inline setstates(fa::FinalizedAlgorithm, states) = finalstep(setstates(inneralgorithm(fa), states), finalfunction(fa))
@inline _attach_registry(fa::FinalizedAlgorithm, registry::NameSpaceRegistry) = finalstep(_attach_registry(inneralgorithm(fa), registry), finalfunction(fa))

function update_keys(fa::FinalizedAlgorithm, registry::NameSpaceRegistry)
    return finalstep(update_keys(inneralgorithm(fa), registry), finalfunction(fa))
end

@inline Base.length(fa::FinalizedAlgorithm) = length(inneralgorithm(fa))
@inline Base.eachindex(fa::FinalizedAlgorithm) = eachindex(inneralgorithm(fa))
@inline cleanup(fa::FinalizedAlgorithm, context) = cleanup(inneralgorithm(fa), context)
@inline cleanup(fa::FinalizedAlgorithm, lc::LoopContext) = cleanup(inneralgorithm(fa), lc)

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

Base.@nospecializeinfer function _strip_nested_finalized_algorithm(@nospecialize(algo))
    return algo
end

function _strip_nested_finalized_algorithm(fa::FinalizedAlgorithm)
    @warn "`FinalizedAlgorithm` is root-only. Dropping its final wrapper because it was used inside another LoopAlgorithm."
    return inneralgorithm(fa)
end

Base.@nospecializeinfer function _strip_nested_finalized_algorithm(@nospecialize(pair::Pair))
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

##########################################
########## Its inner algorithm's #########
##########################################

# What a `FinalizedAlgorithm` answers with its inner algorithm's answer: its plan, namespaces, key source, loop
# cursor, declared locals and states.
@inline getplan(fa::FinalizedAlgorithm) = getplan(inneralgorithm(fa))
@inline getplan(::Type{FA}) where {LA, FA<:FinalizedAlgorithm{LA}} = getplan(LA)

@inline _namespace_tuple(loop::FinalizedAlgorithm) = _namespace_tuple(inneralgorithm(loop))
@inline _namespace_tuple(::Type{FA}) where {LA,FA<:FinalizedAlgorithm{LA}} = _namespace_tuple(LA)

@inline _key_source(loop::FinalizedAlgorithm) = inneralgorithm(loop)
@inline _key_source(::Type{FA}) where {LA,FA<:FinalizedAlgorithm{LA}} = LA

"""Build a loop cursor from a finalized wrapper by using its inner loop."""
@inline loop_cursor(fa::FinalizedAlgorithm, pausable::Val{Pausable} = Val(false)) where {Pausable} =
    loop_cursor(inneralgorithm(fa), pausable)

@inline collect_tree_locals(fa::FinalizedAlgorithm) = collect_tree_locals(inneralgorithm(fa))

states(fa::FinalizedAlgorithm) = states(inneralgorithm(fa))

##########################################
########## Hook extensions ###############
##########################################
# The result of a run is its final function applied to the context after cleanup (LoopAlgorithms/Hooks.jl).

"""The result of a run: the final function applied to the context after cleanup."""
@inline function loop_final_result(fa::FA, cleaned_context::C) where {FA<:FinalizedAlgorithm, C}
    return finalfunction(fa)(cleaned_context)
end

"""
The result of a run: the final function applied to the context after cleanup, and to the run's runtime context when the
final function takes two arguments.
"""
@inline function loop_final_result(fa::FA, cleaned_context::C, runtime_context::RC) where {FA<:FinalizedAlgorithm, C, RC}
    final = finalfunction(fa)
    return applicable(final, cleaned_context, runtime_context) ? final(cleaned_context, runtime_context) : final(cleaned_context)
end
