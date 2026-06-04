"""
Re-initialize one registered subcontext inside an existing `ProcessContext`.

The target can be provided either as its symbol key or as the registered algorithm
reference. `inputs` are merged into that subcontext before `init`, and `overrides`
are merged afterwards.
"""
Base.@constprop :aggressive function initcontext(context::C, s::Symbol; inputs::I = (;), overrides::O = (;)) where {C<:ProcessContext, I, O}
    # TODO: TYPE INSTABLE
    reg = @inline getregistry(context)
    identified_algo = reg[s]
    return initcontext(context, identified_algo; inputs, overrides)
end

Base.@constprop :aggressive function initcontext(context::C, algo::A; inputs::I = (;), overrides::O = (;)) where {C<:ProcessContext, A, I, O}
    reg = getregistry(context)
    identified_algo = get(reg, algo, nothing)
    if isnothing(identified_algo) && algo isa ProcessEntity
        identified_algo = reg[typeof(algo)]
    elseif isnothing(identified_algo)
        identified_algo = reg[algo]
    end
    return initcontext(context, identified_algo; inputs, overrides)
end

function initcontext(context::C, identified_algo::IA; inputs::I = (;), overrides::O = (;)) where {C<:ProcessContext, IA<:IdentifiableAlgo, I, O}
    key = getkey(identified_algo)
    inputcontext = isempty(inputs) ? context : merge_into_subcontexts(context, (;key => inputs))
    prepared_context = init(identified_algo, inputcontext)
    return isempty(overrides) ? prepared_context : merge_into_subcontexts(prepared_context, (;key => overrides))
end
