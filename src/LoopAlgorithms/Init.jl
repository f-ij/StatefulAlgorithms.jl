"""
Set up an empty ProcessContext for a LoopAlgorithm with given shared specifications
Inputargs are given as a NamedTuple of (;algo_name => (; inputname1 = value1, ...), ...)
"""
@inline function init(sa::IA, inputcontext::C, runtimecontext::RC) where {IA<:IdentifiableAlgo,C<:ProcessContext,RC<:ProcessContext}
    name = getkey(sa)
    inputcontext = merge_into_subcontexts(inputcontext, (;name => (;_instance = sa)))
    inputview = @inline view(inputcontext, runtimecontext, sa)
    prepared = @inline init(getalgo(sa), inputview)
    return @inline replace(inputcontext, (;name => prepared))
end

@inline function cleanup(sa::IA, context::C, runtimecontext::RC) where {IA<:IdentifiableAlgo,C<:ProcessContext,RC<:ProcessContext}
    contextview = view(context, runtimecontext, sa)
    cleanup_args = @inline cleanup(getalgo(sa), contextview)
    return @inline merge(contextview, cleanup_args)
end

@inline function init(algo::A, context::C, runtimecontext::RC) where {A<:ProcessAlgorithm,C<:ProcessContext,RC<:ProcessContext}
    return @inline init(algo, context)
end

@inline function cleanup(algo::A, context::C, runtimecontext::RC) where {A<:ProcessAlgorithm,C<:ProcessContext,RC<:ProcessContext}
    cleaned = @inline cleanup(algo, context)
    return cleaned, runtimecontext
end

function init(algos::LA, inputcontext::C) where {LA<:AbstractLoopAlgorithm,C<:AbstractContext}
    runtimecontext = @inline _empty_context()
    return @inline init(algos, inputcontext, runtimecontext)
end

function init(algos::LA, inputcontext::C, runtimecontext::RC) where {LA<:AbstractLoopAlgorithm,C<:ProcessContext,RC<:ProcessContext}
    registry = @inline getregistry(inputcontext)
    named_algos = @inline all_algos(registry)

    context = @inline unrollreplace_withargs(inputcontext, named_algos; args = (runtimecontext,)) do context, named_algo, runtimecontext
        @inline init(named_algo, context, runtimecontext)
    end

    return context
end

function cleanup(algos::LA, context) where {LA<:AbstractLoopAlgorithm}
    runtimecontext = @inline _empty_context()
    context, _ = @inline cleanup(algos, context, runtimecontext)
    return context
end

function cleanup(algos::LA, context::C, runtimecontext::RC) where {LA<:AbstractLoopAlgorithm,C<:ProcessContext,RC<:ProcessContext}
    registry = getregistry(context)
    named_algos = all_algos(registry)

    # Keep cleanup on the same statically unrolled path as init. A runtime loop
    # over heterogeneous registered algorithms boxes the returned context tuple.
    return @inline unrollreplace((context, runtimecontext), named_algos) do state, named_algo
        @inline cleanup(named_algo, getfield(state, 1), getfield(state, 2))
    end
end


"""
For testing purposes, allow init to be called with a NamedTuple of input arguments instead of a ProcessContext
    This works like a subcontext
"""
function init(algos::LA, input::NamedTuple) where {LA<:AbstractLoopAlgorithm}
    # If prepared from a namedtuple, create an empty context first
    newcontext = ProcessContext(algos)
    
    registry = getregistry(newcontext)
    named_algos = all_named_algos(registry)


    prepared_subcontexts = named_flat_collect_broadcast(named_algos) do named_algo
        init(named_algo, get(input, getkey(named_algo), (;)))
    end


    newcontext = replace(newcontext, prepared_subcontexts)
    
    return newcontext
end
