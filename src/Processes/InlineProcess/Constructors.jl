#=
Building an `InlineProcess`: the plan is initialized (or given its `context`) and the lifetime normalized
(`_prepare_inline_process`), then the struct is made with its one session (`_construct_inline_process`).
=#

"""
    InlineProcess(func, Init(...), Override(...); repeats, lifetime, context)

An inline process running `func`: the plan is initialized (or given its `context`) and the lifetime made from `repeats`
or `lifetime` (`_prepare_inline_process`), then the process is built around them (`_construct_inline_process`).
"""
InlineProcess(func::Func, inputs_overrides::Vararg{Any,N}) where {Func,N} =
    _build_inline_process(func, inputs_overrides, nothing, nothing, (;))
# The keyword call, by hand: Julia's own specializes on the keywords' `NamedTuple`, whose type has the handles' uuids
# (a lifetime's `Var`), so it compiled once for every new set of handles.
function Core.kwcall(kw::NamedTuple, ::Type{InlineProcess}, func, inputs_overrides...)
    rest = Base.structdiff(kw, NamedTuple{(:context, :lifetime)})
    return _build_inline_process(func, inputs_overrides, get(kw, :context, nothing), get(kw, :lifetime, nothing), rest)
end
function _build_inline_process(func::Func, inputs_overrides::Tuple, context::C, lifetime::LT, kwargs::NamedTuple) where {Func, C, LT}
    algo, prepared_context, lifetime = _prepare_inline_process(normalize_process_algo(func), inputs_overrides...; context, lifetime, kwargs...)
    return _construct_inline_process(algo, prepared_context, lifetime)
end

"""The plan, initialized or with the given `context`, its context and the lifetime a new `InlineProcess` gets."""
@inline function _prepare_inline_process(algo, inputs_overrides...; repeats=nothing, lifetime=nothing, context=nothing)
    given = normalize_lifetime_arguments(algo, nothing, lifetime, repeats)
    lifetime = isnothing(given) ? Repeat(1) : given
    algo = isnothing(context) ? init(algo, inputs_overrides...; lifetime) : _with_lifecycle(resolve(algo), context, (), ())
    return algo, getpersistentcontext(algo), lifetime
end

"""The `InlineProcess` around a prepared plan, its context and lifetime, with its one session."""
function _construct_inline_process(algo::TD, context::C, lifetime::Lt) where {TD, C, Lt}
    ip = InlineProcess{TD, C, Lt}(uuid1(), algo, context, false, lifetime, InlineSession())
    precompile_interface(ip)   # src/PrecompileInterface.jl
    return ip
end
