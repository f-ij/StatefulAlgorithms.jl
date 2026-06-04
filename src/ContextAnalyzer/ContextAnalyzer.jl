export ContextAnalyser,
    ContextAnalyzer,
    ContextAnalyserMemory,
    ContextAnalyserView,
    ContextAnalyserEvent,
    analyse_init,
    analyse_inits,
    analyse_step,
    analyse_steps,
    requested_inputs,
    stored_inputs,
    printevents

struct ContextAnalyserEvent
    kind::Symbol
    view::Union{Nothing, Symbol}
    name::Any
    payload::Any
end

Base.show(io::IO, event::ContextAnalyserEvent) = print(
    io,
    "ContextAnalyserEvent(",
    "kind=", event.kind,
    ", view=", event.view,
    ", name=", repr(event.name),
    ", payload=", repr(event.payload),
    ")",
)

Base.@kwdef mutable struct ContextAnalyserMemory
    events::Vector{ContextAnalyserEvent} = ContextAnalyserEvent[]
    view_algos::Dict{Symbol, Any} = Dict{Symbol, Any}()
    requested_inputs::Dict{Symbol, Vector{Symbol}} = Dict{Symbol, Vector{Symbol}}()
    inputs::Dict{Symbol, NamedTuple} = Dict{Symbol, NamedTuple}()
    errors::Vector{NamedTuple{(:view, :error), Tuple{Union{Nothing, Symbol}, String}}} = NamedTuple{(:view, :error), Tuple{Union{Nothing, Symbol}, String}}[]
end

struct ContextAnalyser{G} <: AbstractContext
    memory::ContextAnalyserMemory
    globals::G
end

const ContextAnalyzer = ContextAnalyser

struct ContextAnalyserView{A, I} <: AbstractContext
    analyser::A
    instance::I
end

function _normalize_context_analyser_input(value)
    if value isa NamedTuple
        return value
    elseif value isa AbstractDict
        pairs_vec = Pair{Symbol, Any}[]
        for (key, val) in pairs(value)
            key isa Symbol || error("ContextAnalyser inputs must use Symbol keys, got $(key)")
            push!(pairs_vec, key => val)
        end
        return (; pairs_vec...)
    else
        error("ContextAnalyser inputs for one view must be a NamedTuple or AbstractDict, got $(typeof(value))")
    end
end

function _normalize_context_analyser_inputs(inputs)
    normalized = Dict{Symbol, NamedTuple}()
    for name in propertynames(inputs)
        value = getproperty(inputs, name)
        normalized[name] = _normalize_context_analyser_input(value)
    end
    return normalized
end

function ContextAnalyser(; globals = (; lifetime = Indefinite()), inputs = (;))
    memory = ContextAnalyserMemory(inputs = _normalize_context_analyser_inputs(inputs))
    return ContextAnalyser(memory, globals)
end

@inline getglobals(analyser::ContextAnalyser) = getfield(analyser, :globals)
@inline getglobals(viewed::ContextAnalyserView) = getglobals(getfield(viewed, :analyser))
@inline this_instance(viewed::ContextAnalyserView) = getfield(viewed, :instance)

@inline getregistry(::ContextAnalyser) = nothing
@inline getregistry(::ContextAnalyserView) = nothing
@inline getmultiplier(::ContextAnalyserView, _) = 1

function _show_view_target(io::IO, view_key::Symbol, algo)
    print(io, view_key, " => ", algo)
end

function Base.show(io::IO, memory::ContextAnalyserMemory)
    println(io, "ContextAnalyserMemory")

    if isempty(memory.view_algos)
        println(io, "  views: <none>")
    else
        println(io, "  views:")
        for view_key in sort!(collect(keys(memory.view_algos)); by = string)
            print(io, "    ")
            _show_view_target(io, view_key, memory.view_algos[view_key])
            println(io)
        end
    end

    if isempty(memory.requested_inputs)
        println(io, "  requested inputs: <none>")
    else
        println(io, "  requested inputs:")
        for view_key in sort!(collect(keys(memory.requested_inputs)); by = string)
            names = memory.requested_inputs[view_key]
            println(io, "    ", view_key, ": ", names)
        end
    end

    if isempty(memory.inputs)
        println(io, "  stored inputs: <none>")
    else
        println(io, "  stored inputs:")
        for view_key in sort!(collect(keys(memory.inputs)); by = string)
            println(io, "    ", view_key, ": ", memory.inputs[view_key])
        end
    end

    if isempty(memory.errors)
        println(io, "  errors: <none>")
    else
        println(io, "  errors: ", length(memory.errors), " captured")
    end

    println(io, "  events: ", length(memory.events), " captured")

    return nothing
end

Base.show(io::IO, analyser::ContextAnalyser) = show(io, getfield(analyser, :memory))

@inline function _safe_getkey(obj)
    try
        return getkey(obj)
    catch
        return nothing
    end
end

@inline function _safe_getalgo(obj)
    try
        return getalgo(obj)
    catch
        return obj
    end
end

@inline function _symbol_from_index(idx)
    if idx isa Symbol
        return idx
    end

    key = _safe_getkey(idx)
    return key isa Symbol ? key : nothing
end

@inline function _push_unique!(items::Vector{Symbol}, name::Symbol)
    name in items || push!(items, name)
    return items
end

@inline function _memory(analyser::ContextAnalyser)
    return getfield(analyser, :memory)
end

@inline function _memory(viewed::ContextAnalyserView)
    return _memory(getfield(viewed, :analyser))
end

@inline _view_key(::ContextAnalyser) = nothing
@inline function _view_key(viewed::ContextAnalyserView)
    key = _safe_getkey(this_instance(viewed))
    return key isa Symbol ? key : nothing
end

function _record_event!(ctx, kind::Symbol, name, payload = nothing)
    memory = _memory(ctx)
    view = _view_key(ctx)
    push!(memory.events, ContextAnalyserEvent(kind, view, name, payload))

    symbol = if name isa Symbol
        name
    else
        _symbol_from_index(name)
    end
    if !isnothing(view) && !isnothing(symbol)
        inputs = get!(memory.requested_inputs, view, Symbol[])
        _push_unique!(inputs, symbol)
    end

    return nothing
end

function _record_error!(ctx, err, bt = Base.catch_backtrace())
    memory = _memory(ctx)
    rendered = sprint(showerror, err)
    push!(memory.errors, (; view = _view_key(ctx), error = rendered))
    return nothing
end

@inline requested_inputs(memory::ContextAnalyserMemory) = memory.requested_inputs
@inline requested_inputs(analyser::ContextAnalyser) = requested_inputs(_memory(analyser))
@inline stored_inputs(memory::ContextAnalyserMemory) = memory.inputs
@inline stored_inputs(analyser::ContextAnalyser) = stored_inputs(_memory(analyser))

function printevents(io::IO, memory::ContextAnalyserMemory)
    if isempty(memory.events)
        println(io, "ContextAnalyser events: <none>")
        return nothing
    end

    println(io, "ContextAnalyser events:")
    for event in memory.events
        println(io, "  ", event)
    end
    return nothing
end

@inline printevents(io::IO, analyser::ContextAnalyser) = printevents(io, _memory(analyser))
@inline printevents(memory::ContextAnalyserMemory) = printevents(stdout, memory)
@inline printevents(analyser::ContextAnalyser) = printevents(stdout, analyser)

@inline function _get_stored_input(memory::ContextAnalyserMemory, view::Symbol, name::Symbol)
    return get(get(memory.inputs, view, (;)), name, nothing)
end

@inline function _has_stored_input(memory::ContextAnalyserMemory, view::Symbol, name::Symbol)
    return haskey(get(memory.inputs, view, (;)), name)
end

function _merge_stored_input!(memory::ContextAnalyserMemory, view::Symbol, values::NamedTuple)
    current = get(memory.inputs, view, (;))
    memory.inputs[view] = merge(current, values)
    return memory.inputs[view]
end

function _merge_view_return!(viewed::ContextAnalyserView, values::NamedTuple)
    view = _view_key(viewed)
    if !isnothing(view)
        _merge_stored_input!(_memory(viewed), view, values)
    end
    return getfield(viewed, :analyser)
end

function Base.view(analyser::ContextAnalyser, instance; inject = (;))
    memory = _memory(analyser)
    view_key = _safe_getkey(instance)
    if view_key isa Symbol
        memory.view_algos[view_key] = _safe_getalgo(instance)
    end
    push!(memory.events, ContextAnalyserEvent(:view, nothing, view_key, instance))
    return ContextAnalyserView(analyser, instance)
end

@inline function Base.view(viewed::ContextAnalyserView, instance; inject = (;))
    return view(getfield(viewed, :analyser), instance; inject)
end

@inline Base.propertynames(::ContextAnalyser) = ()
@inline Base.propertynames(::ContextAnalyserView) = ()
@inline Base.keys(ctx::Union{ContextAnalyser, ContextAnalyserView}) = propertynames(ctx)

function Base.haskey(ctx::Union{ContextAnalyser, ContextAnalyserView}, name::Symbol)
    if ctx isa ContextAnalyserView
        view = _view_key(ctx)
        if !isnothing(view) && _has_stored_input(_memory(ctx), view, name)
            return true
        end
    end
    _record_event!(ctx, :haskey, name)
    return false
end

function Base.get(ctx::Union{ContextAnalyser, ContextAnalyserView}, name::Symbol, default)
    if ctx isa ContextAnalyserView
        view = _view_key(ctx)
        if !isnothing(view) && _has_stored_input(_memory(ctx), view, name)
            return _get_stored_input(_memory(ctx), view, name)
        end
    end
    _record_event!(ctx, :get, name, default)
    return default
end

function Base.getproperty(analyser::ContextAnalyser, name::Symbol)
    if name === :memory || name === :globals
        return getfield(analyser, name)
    end

    if haskey(_memory(analyser).inputs, name)
        return _memory(analyser).inputs[name]
    end

    _record_event!(analyser, :getproperty, name)
    return nothing
end

function Base.getproperty(viewed::ContextAnalyserView, name::Symbol)
    if name === :analyser || name === :instance
        return getfield(viewed, name)
    end

    view = _view_key(viewed)
    if !isnothing(view) && _has_stored_input(_memory(viewed), view, name)
        return _get_stored_input(_memory(viewed), view, name)
    end

    _record_event!(viewed, :getproperty, name)
    return nothing
end

function Base.getindex(ctx::Union{ContextAnalyser, ContextAnalyserView}, idx)
    key = _symbol_from_index(idx)
    if !isnothing(key) && haskey(_memory(ctx).inputs, key)
        return _memory(ctx).inputs[key]
    end
    _record_event!(ctx, :getindex, idx)
    return nothing
end

@inline Base.merge(viewed::ContextAnalyserView, ::Nothing) = getfield(viewed, :analyser)
@inline function Base.merge(viewed::ContextAnalyserView, args::NamedTuple)
    return _merge_view_return!(viewed, args)
end
@inline Base.merge(viewed::ContextAnalyserView, args) = error("Step, init and cleanup must return namedtuple, trying to merge $(args) into ContextAnalyserView $(viewed)")
@inline Base.replace(viewed::ContextAnalyserView, args::NamedTuple) = _merge_view_return!(viewed, args)
function analyse_init(algo, context::Union{ContextAnalyser, ContextAnalyserView})
    try
        result = init(algo, context)
        if context isa ContextAnalyserView && result isa NamedTuple
            view = _view_key(context)
            if !isnothing(view)
                _merge_stored_input!(_memory(context), view, result)
            end
        end
    catch err
        _record_error!(context, err)
    end
    return context
end

function analyse_init(sa::AbstractIdentifiableAlgo, analyser::ContextAnalyser)
    viewed = view(analyser, sa)
    analyse_init(getalgo(sa), viewed)
    return analyser
end

function analyse_step(algo, context::Union{ContextAnalyser, ContextAnalyserView})
    try
        result = step!(algo, context)
        if context isa ContextAnalyserView && result isa NamedTuple
            view = _view_key(context)
            if !isnothing(view)
                _merge_stored_input!(_memory(context), view, result)
            end
        end
    catch err
        _record_error!(context, err)
    end
    return context
end

function analyse_step(sa::AbstractIdentifiableAlgo, analyser::ContextAnalyser)
    try
        step!(sa, analyser)
    catch err
        _record_error!(analyser, err)
    end
    return analyser
end

function _default_analysis_globals(la)
    return (; lifetime = Indefinite(), algo = la)
end

_analysis_mock_loopalgorithm(x) = x

function _analysis_mock_loopalgorithm(sa::AbstractIdentifiableAlgo)
    inner = getalgo(sa)
    if inner isa AbstractLoopAlgorithm
        return setfield(sa, :func, _analysis_mock_loopalgorithm(inner))
    end
    return sa
end

function _analysis_mock_loopalgorithm(ca::CompositeAlgorithm)
    funcs = map(_analysis_mock_loopalgorithm, getalgos(ca))
    mocked = newfuncs(ca, funcs)
    mocked = setintervals(mocked, ntuple(_ -> 1, length(funcs)))
    reset!(mocked)
    return mocked
end

function _analysis_mock_loopalgorithm(r::Routine)
    funcs = map(_analysis_mock_loopalgorithm, getalgos(r))
    mocked = newfuncs(r, funcs)
    mocked = setrepeats(mocked, ntuple(_ -> 1, length(funcs)))
    reset!(mocked)
    return mocked
end

function analyse_inits(la::ALA; globals = (;), inputs = (;)) where {ALA<:AbstractLoopAlgorithm}
    resolved = resolve(la)
    mocked = _analysis_mock_loopalgorithm(resolved)
    analyser = ContextAnalyser(; globals = merge(_default_analysis_globals(mocked), globals), inputs)

    for state in flat_states(mocked)
        analyse_init(state, analyser)
    end

    for algo in all_algos(getregistry(mocked))
        analyse_init(algo, analyser)
    end

    return analyser
end

function analyse_steps(la::ALA; globals = (;), inputs = (;), init = true) where {ALA<:AbstractLoopAlgorithm}
    resolved = resolve(la)
    mocked = _analysis_mock_loopalgorithm(resolved)
    analyser = ContextAnalyser(; globals = merge(_default_analysis_globals(mocked), globals), inputs)

    if init
        for state in flat_states(mocked)
            analyse_init(state, analyser)
        end

        for algo in all_algos(getregistry(mocked))
            analyse_init(algo, analyser)
        end
    end

    for algo in all_algos(getregistry(mocked))
        analyse_step(algo, analyser)
    end

    return analyser
end
