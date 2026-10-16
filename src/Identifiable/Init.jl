"""
Get the name from a IdentifiableAlgo and init the inputs for it
"""
@inline function init(sa::IdentifiableAlgo, inputcontext::AbstractContext)
    return @inline init(sa, InitContext(inputcontext, sa, Indefinite()))
end

@inline function init(sa::IA, ic::I) where {IA<:IdentifiableAlgo,I<:InitContext}
    name = getkey(sa)
    inputcontext = merge_into_subcontexts(getpersistent(ic), (;name => (;_instance = sa)))
    inputview = @inline view(withpersistent(ic, inputcontext), sa)
    prepared = @inline init(getalgo(sa), inputview)
    return @inline replace(inputcontext, (;name => prepared))
end

"""
Direct init running for debugging
"""
@inline function init(sa::IdentifiableAlgo, input::NamedTuple = (;))
    return (;getkey(sa) => init(getalgo(sa), input))
end

function cleanup(sa::IdentifiableAlgo, persistent_context::AbstractContext)
    return @inline getpersistent(cleanup(sa, LoopContext(persistent_context, _empty_context())))
end

@inline function cleanup(sa::IA, lc::L) where {IA<:IdentifiableAlgo,L<:LoopContext}
    contextview = view(lc, sa)
    cleanup_args = @inline cleanup(getalgo(sa), contextview)
    return @inline merge(contextview, cleanup_args)
end
