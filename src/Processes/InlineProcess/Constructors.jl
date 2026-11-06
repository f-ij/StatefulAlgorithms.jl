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
# Untyped, as `_build_process`: a lifetime from outside the plan gets the plan's numbers (`number_by_keymap`) first.
Base.@nospecializeinfer function _build_inline_process(@nospecialize(func), @nospecialize(inputs_overrides::Tuple), @nospecialize(context), @nospecialize(lifetime), @nospecialize(kwargs::NamedTuple))
    resolved = resolve(parse_plan(func))
    lifetime = number_by_keymap_dynamic(lifetime, getkeymap(resolved))
    algo, prepared_context, lifetime = _prepare_inline_process(resolved, inputs_overrides...; context, lifetime, kwargs...)
    return _construct_inline_process(algo, prepared_context, _stored_specs(algo, inputs_overrides), lifetime)
end

"""
The resolved plan, its starting context (from `setup`, or the given `context`) and the lifetime a new `InlineProcess`
gets. As for a `Process`: plan and context keep the `UniqueKeyMap` in their registry (`with_keymap`); `init` runs
without it (`_setup`).
"""
@inline function _prepare_inline_process(algo, inputs_overrides...; repeats=nothing, lifetime=nothing, context=nothing)
    lifetime = something(parse_lifetime(lifetime, repeats), Repeat(1))
    algo = resolve(algo)
    context = with_keymap(isnothing(context) ? first(_setup(algo, inputs_overrides...; lifetime)) : context, getkeymap(algo))
    # The lifetime's `Var`s by key (`resolve_var_keys`), once: the loop reads them without the registry.
    return algo, context, resolve_var_keys(lifetime, getregistry(context))
end

"""The `InlineProcess` around a prepared plan, its context, specs and lifetime, with its one session."""
function _construct_inline_process(algo::TD, context::C, specs::S, lifetime::Lt) where {TD, C, S<:Tuple, Lt}
    ip = InlineProcess{TD, C, Lt, S}(uuid1(), algo, context, specs, lifetime, InlineSession())
    precompile_interface(ip)   # src/PrecompileInterface.jl
    return ip
end
