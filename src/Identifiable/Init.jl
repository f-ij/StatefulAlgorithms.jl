"""
Get the name from a IdentifiableAlgo and init the inputs for it
"""
@inline function init(sa::IdentifiableAlgo, inputcontext::AbstractContext)
    return @inline init(sa, InitContext(inputcontext, sa, Indefinite()))
end

"""
Direct init running for debugging
"""
@inline function init(sa::IdentifiableAlgo, input::NamedTuple = (;))
    return (;getkey(sa) => init(getalgo(sa), input))
end

function cleanup(sa::IdentifiableAlgo, context::AbstractContext)
    return @inline getcontext(cleanup(sa, LoopContext(context, _empty_context())))
end
