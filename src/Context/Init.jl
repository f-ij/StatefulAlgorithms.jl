"""
    init_namespace(context, identified_algo; inputs = (;), overrides = (;)) -> context

Runs the `init` of one registered algorithm or state, `identified_algo`, on `context` and returns the new context; the
other namespaces are kept. `inputs` are merged into its subcontext before its `init`, `overrides` after it. Written for
`init(plan, context, Only(...), ...)`, which calls it for each target the `Only` names.
"""
function init_namespace(context::C, identified_algo::IA; inputs::I = (;), overrides::O = (;)) where {C<:ProcessContext, IA<:IdentifiableAlgo, I, O}
    key = getkey(identified_algo)
    inputcontext = isempty(inputs) ? context : merge_into_subcontexts(context, (;key => inputs))
    prepared_context = init(identified_algo, inputcontext)
    return isempty(overrides) ? prepared_context : merge_into_subcontexts(prepared_context, (;key => overrides))
end
