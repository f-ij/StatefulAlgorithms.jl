#=
Building a `Process`: the plan is set up (`setup`, or given its `context`) and the lifetime normalized
(`_prepare_process`), then the struct is made with a session for the lifetime's type and registered in `processlist`
(`_construct_process`).
=#

"""
    Process(func, InitArgs(...), Override(...); context, repeats, lifetime, timeout)

A process running `func`: the plan is set up with the specs (or given its `context`) and the lifetime made from
`repeats` or `lifetime` (`_prepare_process`), then the process is built around them (`_construct_process`). The process
keeps the context and the specs (resolved and merged per target, `init!` merges new ones over them); the plan holds
neither.
"""
Process(func::Func, inputs_overrides::Vararg{Any,N}) where {Func,N} = _build_process(func, inputs_overrides, nothing, nothing, (;))
# The keyword call, by hand: Julia's own specializes on the keywords' `NamedTuple`, whose type has the handles' uuids
# (a lifetime's `Var`), so it compiled once for every new set of handles.
function Core.kwcall(kw::NamedTuple, ::Type{Process}, func, inputs_overrides...)
    rest = Base.structdiff(kw, NamedTuple{(:context, :lifetime)})
    return _build_process(func, inputs_overrides, get(kw, :context, nothing), get(kw, :lifetime, nothing), rest)
end
# Untyped: the plan is resolved first, so a lifetime from outside the plan gets the plan's numbers for its `Unique`
# handles (`number_by_keymap`) before anything typed on it is called.
Base.@nospecializeinfer function _build_process(@nospecialize(func), @nospecialize(inputs_overrides::Tuple), @nospecialize(context), @nospecialize(lifetime), @nospecialize(kwargs::NamedTuple))
    resolved = resolve(parse_plan(func))
    lifetime = number_by_keymap_dynamic(lifetime, getkeymap(resolved))
    algo, context, specs, lifetime, timeout = _prepare_process(resolved, inputs_overrides...; context, lifetime, kwargs...)
    return _construct_process(algo, context, specs, lifetime, timeout)
end

"""
The resolved plan, its starting context (from `setup`, or the given `context`), the specs, the lifetime and the timeout
a new `Process` gets. The plan keeps the `UniqueKeyMap` in its registry, and so does the context (`with_keymap`); `init`
runs without it (`_setup`).
"""
function _prepare_process(algo::A, inputs_overrides::Vararg{Any,N}; context::C = nothing, repeats = nothing, lifetime = nothing, timeout = 1.0) where {A,N,C}
    lifetime = something(parse_lifetime(lifetime, repeats), default_lifetime(algo))
    algo = resolve(algo)
    if isnothing(context)
        context = first(_setup(algo, inputs_overrides...; lifetime))
    else
        isempty(inputs_overrides) || error("Pass either an initialized `context` or init/override specs to `Process`, not both.")
    end
    return algo, with_keymap(context, getkeymap(algo)), _stored_specs(algo, inputs_overrides), lifetime, timeout
end

"""The `Process` around a prepared plan and context: its session (made for the lifetime's type) and its place in `processlist`."""
function _construct_process(algo::F, context::ProcessContext, specs::Tuple, lifetime::LT, timeout) where {F<:AbstractLoopAlgorithm, LT}
    C = typeof(loop_cursor(getplan(algo), Val(true)))
    session = InteractiveSession{C}(lifetime)
    p = Process{F, C}(uuid1(), algo, lifetime, context, specs, nothing, timeout, nothing, Threads.ReentrantLock(), nothing, RuntimeListeners(), session)

    register_process!(p)
    precompile_interface(p)   # src/PrecompileInterface.jl
    
    finalizer(remove_process!, p)
    return p
end

function Process(func, repeats::Int; overrides = tuple(), timeout = 1.0, context = nothing)
    overrides_tuple = overrides isa Tuple ? overrides : (overrides,)
    return Process(func, overrides_tuple...; repeats = repeats, timeout, context)
end
