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

"""Return the persistent state produced by lifecycle init."""
@inline _init_state_context(context::C, base::B) where {C<:ProcessContext,B<:ProcessContext} = context
@inline _init_state_context(patch::P, base::B) where {P<:NamedTuple,B<:ProcessContext} =
    @inline merge_into_subcontexts(base, patch)

"""
Make a context from an algo and empty context
"""
function initcontext(algo::F, c::ProcessContext; lifetime = Indefinite()) where {F <: LoopSpec}
    algo = resolve(algo)
    @DebugMode "Preparing context for algo $(algo) with input context $c"
    @DebugMode "Overrides are ()"

    prepared_context = init(algo, InitContext(c, algo, lifetime))
    @DebugMode "Prepared in initcontext context is $prepared_context"

    state_context = @inline _init_state_context(prepared_context, c)
    return @inline apply_redirect_specs(state_context, algo)
end

function initcontext(algo::F, c::ProcessContext = ProcessContext(algo), overrides_and_inputs::InputInterface...; lifetime = Indefinite()) where {F <: LoopSpec}
    algo = resolve(algo)
    resolved = _resolve_lifecycle_specs(getregistry(c), overrides_and_inputs)
    inputs, overrides, interactives = _split_lifecycle_specs(resolved)
    input_state_context = merge_resolved_inputs(c, inputs)
    @DebugMode "Preparing context for algo $(algo) with input context $input_state_context"
    @DebugMode "Overrides are $overrides"

    prepared_context = init(algo, InitContext(input_state_context, algo, lifetime))
    @DebugMode "Prepared in initcontext context is $prepared_context"

    prepared_state_context = @inline _init_state_context(prepared_context, input_state_context)
    overridden_context = merge_resolved_inputs(prepared_state_context, overrides)

    interactive_context = @inline apply_interactive_specs(overridden_context, interactives)
    return @inline apply_redirect_specs(interactive_context, algo)
end

function makecontext(p::AbstractProcess, inputs_overrides...; lifetime=nothing)
    lt = isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime
    context(init(getalgo(p), inputs_overrides...; lifetime = lt))
end
"""Build a fresh context for a process by replaying lifecycle init on its LA."""
function makecontext!(p::AbstractProcess, inputs_overrides...; lifetime=nothing)
    c = makecontext(p, inputs_overrides...; lifetime)
    p isa Process ? commit_context!(p, c) : context(p, c)
end

function cleanup(p::AbstractProcess)
    lifetime = tasklifetime(p)
    returncontext = cleanup(getalgo(p), (;process = p, lifetime, _context(p)...))
    return deletekeys(returncontext, :process, :lifetime)
end

export preparedata!, cleanup
