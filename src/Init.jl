export initcontext
"""
So that warnings are only printed once per type per session
"""
const warnset = Set{Any}()
"""
Fallback init
"""
function init(t::T, c::Any) where T
    if !in(T, warnset)
        @warn "No init function defined for var $t with type $T, returning empty context"
        push!(warnset, T)
    end
    (;)
end

"""Build the runtime frame visible only while lifecycle init runs."""
@inline function _init_runtime_context(algo::F, lifetime::LT) where {F<:AbstractLoopAlgorithm,LT}
    return @inline _merge_into_globals(_empty_context(), (; algo, lifetime))
end

"""Return the persistent state produced by lifecycle init."""
@inline _init_state_context(context::C, base::B) where {C<:ProcessContext,B<:ProcessContext} = context
@inline _init_state_context(patch::P, base::B) where {P<:NamedTuple,B<:ProcessContext} =
    @inline merge_into_subcontexts(base, patch)

"""
Make a context from an algo and empty context
"""
function initcontext(algo::F, c::ProcessContext; lifetime = Indefinite()) where {F <: AbstractLoopAlgorithm}
    runtime_context = @inline _init_runtime_context(algo, lifetime)

    @DebugMode "Preparing context for algo $(algo) with input context $c"
    @DebugMode "Overrides are ()"

    prepared_context = init(algo, c, runtime_context)
    @DebugMode "Prepared in initcontext context is $prepared_context"

    return @inline _init_state_context(prepared_context, c)
end

function initcontext(algo::F, c::ProcessContext = ProcessContext(algo), overrides_and_inputs::InputInterface...; lifetime = Indefinite()) where {F <: AbstractLoopAlgorithm}
    resolved = _resolve_lifecycle_specs(getregistry(c), overrides_and_inputs)
    inputs, overrides, interactives = _split_lifecycle_specs(resolved)
    input_state_context = merge_resolved_inputs(c, inputs)
    runtime_context = @inline _init_runtime_context(algo, lifetime)

    @DebugMode "Preparing context for algo $(algo) with input context $input_state_context"
    @DebugMode "Overrides are $overrides"

    prepared_context = init(algo, input_state_context, runtime_context)
    @DebugMode "Prepared in initcontext context is $prepared_context"

    prepared_state_context = @inline _init_state_context(prepared_context, input_state_context)
    overridden_context = merge_resolved_inputs(prepared_state_context, overrides)

    return @inline apply_interactive_specs(overridden_context, interactives)
end

function makecontext(p::AbstractProcess, inputs_overrides...; lifetime=nothing)
    lt = isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime
    context(init(getalgo(p), inputs_overrides...; lifetime = lt))
end
"""Build a fresh context for a process by replaying lifecycle init on its LA."""
function makecontext!(p::AbstractProcess, inputs_overrides...; lifetime=nothing)
    c = makecontext(p, inputs_overrides...; lifetime)
    context(p,c)
end

function cleanup(p::AbstractProcess)
    lifetime = tasklifetime(p)
    returncontext = cleanup(getalgo(p), (;process = p, lifetime, getcontext(p)...))
    return deletekeys(returncontext, :process, :lifetime)
end

export preparedata!, cleanup
