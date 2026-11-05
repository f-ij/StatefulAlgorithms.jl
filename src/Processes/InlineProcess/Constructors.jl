#=
Building an `InlineProcess`: the plan is set up (`setup`, or given its `context`) and the lifetime normalized
(`_prepare_inline_process`), then the struct is made with its one session (`_construct_inline_process`).
=#

"""
    InlineProcess(func, InitArgs(...), Override(...); repeats, lifetime, context)

An inline process running `func`: the plan is set up with the specs (or given its `context`) and the lifetime made from `repeats`
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
    algo, prepared_context, lifetime = _prepare_inline_process(parse_plan(func), inputs_overrides...; context, lifetime, kwargs...)
    return _construct_inline_process(algo, prepared_context, _stored_specs(algo, inputs_overrides), lifetime)
end

"""The resolved plan, its starting context (from `setup`, or the given `context`) and the lifetime a new `InlineProcess` gets."""
@inline function _prepare_inline_process(algo, inputs_overrides...; repeats=nothing, lifetime=nothing, context=nothing)
    lifetime = something(parse_lifetime(lifetime, repeats), Repeat(1))
    isnothing(context) || return resolve(algo), context, lifetime
    context, algo = setup(algo, inputs_overrides...; lifetime)
    return algo, context, lifetime
end

"""The `InlineProcess` around a prepared plan, its context, specs and lifetime, with its one session."""
function _construct_inline_process(algo::TD, context::C, specs::S, lifetime::Lt) where {TD, C, S<:Tuple, Lt}
    ip = InlineProcess{TD, C, Lt, S}(uuid1(), algo, context, specs, lifetime, InlineSession())
    precompile_interface(ip)   # src/PrecompileInterface.jl
    return ip
end
