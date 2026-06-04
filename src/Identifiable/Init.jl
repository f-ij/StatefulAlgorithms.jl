"""
Get the name from a IdentifiableAlgo and init the inputs for it
"""
@inline function init(sa::IdentifiableAlgo, inputcontext::AbstractContext)
    runtimecontext = @inline _empty_context()
    return @inline init(sa, inputcontext, runtimecontext)
end

@inline function init(sa::IdentifiableAlgo, inputcontext::C, runtimecontext::RC) where {C<:AbstractContext, RC<:AbstractContext}
    name = getkey(sa)
    inputcontext = merge_into_subcontexts(inputcontext, (;name => (;_instance = sa)))
    inputview = @inline view(inputcontext, runtimecontext, sa)
    prepared = @inline init(getalgo(sa), inputview)
    @inline replace(inputcontext, (;name => prepared))
end

"""
Direct init running for debugging
"""
@inline function init(sa::IdentifiableAlgo, input::NamedTuple = (;))
    return (;getkey(sa) => init(getalgo(sa), input))
end

function cleanup(sa::IdentifiableAlgo, context::AbstractContext)
    runtimecontext = @inline _empty_context()
    newcontext, _ = @inline cleanup(sa, context, runtimecontext)
    return newcontext
end

function cleanup(sa::IdentifiableAlgo, context::C, runtimecontext::RC) where {C<:AbstractContext, RC<:AbstractContext}
    contextview = view(context, runtimecontext, sa)
    cleanup_args = @inline cleanup(getalgo(sa), contextview)
    return @inline merge(contextview, cleanup_args)
end
