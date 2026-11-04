#=
Building a `Process`: the plan is initialized (or given its `context`) and the lifetime normalized
(`_prepare_process`), then the struct is made with a session for the lifetime's type and registered in `processlist`
(`_construct_process`).
=#

"""
    Process(func, Init(...), Override(...); context, repeats, lifetime, timeout)

A process running `func`: the plan is initialized (or given its `context`) and the lifetime made from `repeats` or
`lifetime` (`_prepare_process`), then the process is built around them (`_construct_process`).
"""
Process(func::Func, inputs_overrides::Vararg{Any,N}) where {Func,N} = _build_process(func, inputs_overrides, nothing, nothing, (;))
# The keyword call, by hand: Julia's own specializes on the keywords' `NamedTuple`, whose type has the handles' uuids
# (a lifetime's `Var`), so it compiled once for every new set of handles.
function Core.kwcall(kw::NamedTuple, ::Type{Process}, func, inputs_overrides...)
    rest = Base.structdiff(kw, NamedTuple{(:context, :lifetime)})
    return _build_process(func, inputs_overrides, get(kw, :context, nothing), get(kw, :lifetime, nothing), rest)
end
function _build_process(func::Func, inputs_overrides::Tuple, context::C, lifetime::LT, kwargs::NamedTuple) where {Func, C, LT}
    algo, lifetime, timeout = _prepare_process(parse_plan(func), inputs_overrides...; context, lifetime, kwargs...)
    return _construct_process(algo, lifetime, timeout)
end

"""The plan, initialized or with the given `context`, the lifetime and the timeout a new `Process` gets."""
function _prepare_process(algo::A, inputs_overrides::Vararg{Any,N}; context::C = nothing, repeats = nothing, lifetime = nothing, timeout = 1.0) where {A,N,C}
    lifetime = something(parse_lifetime(nothing, lifetime, repeats), default_lifetime(algo))
    algo = _process_constructor_algo(algo, context, inputs_overrides, lifetime)
    prepared_context = isnothing(context) ? getpersistentcontext(algo) : context
    algo = _with_lifecycle(algo, prepared_context, getstoredinits(algo), getstoredoverrides(algo))
    return algo, lifetime, timeout
end

"""The `Process` around a prepared plan: its session (made for the lifetime's type) and its place in `processlist`."""
function _construct_process(algo::F, lifetime::LT, timeout) where {F<:AbstractLoopAlgorithm, LT}
    C = typeof(loop_cursor(getplan(algo), Val(true)))
    session = InteractiveSession{C, LT}()
    p = Process{F, C}(uuid1(), algo, lifetime, nothing, nothing, timeout, nothing, Threads.ReentrantLock(), nothing, RuntimeListeners(), session)

    register_process!(p)
    precompile_interface(p)   # src/PrecompileInterface.jl
    
    finalizer(remove_process!, p)
    return p
end

@inline function _process_constructor_algo(algo::LA, ::Nothing, inputs_overrides::Tuple{}, lifetime::LT) where {LA<:LoopSpec, LT}
    isnothing(getpersistentcontext(algo)) || return algo
    return init(algo; lifetime)
end

@inline function _process_constructor_algo(algo::LA, ::Nothing, inputs_overrides::IO, lifetime::LT) where {LA<:LoopSpec, IO<:Tuple, LT}
    return init(algo, inputs_overrides...; lifetime)
end

@inline function _process_constructor_algo(algo::LA, context::C, inputs_overrides::IO, lifetime::LT) where {LA<:LoopSpec, C, IO<:Tuple, LT}
    isempty(inputs_overrides) || error("Pass either an initialized `context` or init/override specs to `Process`, not both.")
    isnothing(getpersistentcontext(algo)) || return algo
    return _with_lifecycle(resolve(algo), nothing, getstoredinits(algo), getstoredoverrides(algo))
end

function Process(func, repeats::Int; overrides = tuple(), timeout = 1.0, context = nothing)
    overrides_tuple = overrides isa Tuple ? overrides : (overrides,)
    return Process(func, overrides_tuple...; repeats = repeats, timeout, context)
end
