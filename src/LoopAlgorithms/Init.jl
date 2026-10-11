"""
Set up an empty ProcessContext for a LoopAlgorithm with given shared specifications
Inputargs are given as a NamedTuple of (;algo_name => (; inputname1 = value1, ...), ...)
"""
@inline function init(sa::IA, ic::I) where {IA<:IdentifiableAlgo,I<:InitContext}
    name = getkey(sa)
    inputcontext = merge_into_subcontexts(getpersistent(ic), (;name => (;_instance = sa)))
    inputview = @inline view(withpersistent(ic, inputcontext), sa)
    prepared = @inline init(getalgo(sa), inputview)
    return @inline replace(inputcontext, (;name => prepared))
end

@inline function cleanup(sa::IA, lc::L) where {IA<:IdentifiableAlgo,L<:LoopContext}
    contextview = view(lc, sa)
    cleanup_args = @inline cleanup(getalgo(sa), contextview)
    return @inline merge(contextview, cleanup_args)
end

@inline function init(algo::A, ic::I) where {A<:ProcessAlgorithm,I<:InitContext}
    return @inline init(algo, getpersistent(ic))
end

@inline function cleanup(algo::A, lc::L) where {A<:ProcessAlgorithm,L<:LoopContext}
    cleaned = @inline cleanup(algo, getpersistent(lc))
    return @inline withpersistent(lc, cleaned)
end

function init(algos::LA, inputcontext::C) where {LA<:LoopSpec,C<:AbstractContext}
    return @inline init(algos, InitContext(inputcontext, algos, Indefinite()))
end

"""The persistent context that init of every registered algorithm and state builds from `ic`'s persistent context."""
function init(algos::LA, ic::I) where {LA<:LoopSpec,I<:InitContext}
    named_algos = @inline all_algos(getregistry(ic))
    initialized = @inline unrollreplace(ic, named_algos) do ic, named_algo
        @inline withpersistent(ic, init(named_algo, ic))
    end
    return @inline getpersistent(initialized)
end

function cleanup(algos::LA, persistent_context) where {LA<:LoopSpec}
    return @inline getpersistent(cleanup(algos, LoopContext(persistent_context, _empty_context())))
end

function cleanup(algos::LA, lc::L) where {LA<:LoopSpec,L<:LoopContext}
    named_algos = all_algos(getregistry(lc))

    # Keep cleanup on the same statically unrolled path as init. A runtime loop
    # over heterogeneous registered algorithms boxes the returned context.
    return @inline unrollreplace(lc, named_algos) do lc, named_algo
        @inline cleanup(named_algo, lc)
    end
end


"""
For testing purposes, allow init to be called with a NamedTuple of input arguments instead of a ProcessContext
    This works like a subcontext
"""
function init(algos::LA, input::NamedTuple) where {LA<:LoopSpec}
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
