export RuntimeInput, RuntimeInputState, RuntimeInputs


"""
Runtime input declaration produced by DSL `@input`.

`Name`, `T`, and `Required` live in the type so validation specializes on the
declared input contract. `default` is stored only for optional inputs.
"""
struct RuntimeInput{Name, T, Required, Default}
    default::Default
end

RuntimeInput(name::Symbol, ::Type{T}; required::Bool = true, default = nothing) where {T} =
    RuntimeInput{name, T, required, typeof(default)}(default)

"""
Loop option carrying all runtime input declarations for a composed algorithm.

The DSL stores this as an option so `run(...; kwargs...)` can validate keyword
arguments without inspecting the generated step code.
"""
struct RuntimeInputs{Specs} <: RootOption
    specs::Specs
end

RuntimeInputs(specs::Tuple = ()) = RuntimeInputs{typeof(specs)}(specs)

"""Runtime inputs name no algorithm or state, so there is no key to update."""
update_keys(inputs::RuntimeInputs, ::NameSpaceRegistry) = inputs

"""
Registry-visible marker state for runtime input names.

Runtime inputs are not persistent state. This marker exists so the composition
registry can route DSL references such as `temperature` to the runtime input
owner while initialization still produces an empty persistent subcontext.
"""
struct RuntimeInputState{Specs} <: AlgoState
    specs::Specs
end

RuntimeInputState(specs::Tuple = ()) = RuntimeInputState{typeof(specs)}(specs)

StatefulAlgorithms.registry_allowmerge(::Union{RuntimeInputState, Type{<:RuntimeInputState}}) = true
match_by(ia::Union{IdentifiableAlgo{<:RuntimeInputState}, Type{<:IdentifiableAlgo{<:RuntimeInputState}}}) = ValMatcher(getkey(ia))

StatefulAlgorithms.init(::RuntimeInputState, context) = (;)

Base.merge(a::RuntimeInputState, b::RuntimeInputState) = RuntimeInputState((a.specs..., b.specs...))

"""
Return the runtime input declaration bundle attached to `la`.

Runtime input declarations may be stored either as explicit `RuntimeInputs`
options or as `RuntimeInputState` process states. The latter is used by the DSL
so inputs can participate in routing through the registry.
"""
function runtimeinputs(la::LA) where {LA<:LoopSpec}
    inputs = filter_by_type(RuntimeInputs, getoptions(la))
    if !isempty(inputs)
        specs = mapreduce(x -> x.specs, (a, b) -> (a..., b...), inputs; init = ())
        return RuntimeInputs(specs)
    end

    specs = ()
    for state in getstates(la)
        input_state = state isa IdentifiableAlgo ? getalgo(state) : state
        input_state isa RuntimeInputState && (specs = (specs..., input_state.specs...))
    end
    return RuntimeInputs(specs)
end

@inline _runtime_input_name(::RuntimeInput{Name}) where {Name} = Name
@inline _runtime_input_type(::RuntimeInput{Name, T}) where {Name, T} = T
@inline _runtime_input_required(::RuntimeInput{Name, T, Required}) where {Name, T, Required} = Required

"""
Build default keyword values for optional runtime inputs.

Required inputs are intentionally omitted here so validation can report a
missing input instead of silently supplying `nothing`.
"""
function _runtime_input_defaults(specs::Tuple)
    pairs = Pair{Symbol, Any}[] 
    for spec in specs
        _runtime_input_required(spec) || push!(pairs, _runtime_input_name(spec) => spec.default)
    end
    return (; pairs...)
end

"""
Validate one run's keyword arguments against `la`'s runtime input declarations.

This rejects unknown names, checks required inputs, validates typed inputs with
`isa`, and merges optional defaults into the returned `NamedTuple`.
"""
function _validate_runtime_inputs(la::LA, inputs::I) where {LA<:LoopSpec, I<:NamedTuple}
    specs = runtimeinputs(la).specs
    if isempty(specs)
        isempty(inputs) || error("Runtime inputs were passed, but this LoopAlgorithm declares no @input values.")
        return inputs
    end

    allowed = Tuple(_runtime_input_name(spec) for spec in specs)
    for name in keys(inputs)
        name in allowed || error("Unknown runtime input `$name`. Declared inputs are $(allowed).")
    end

    for spec in specs
        name = _runtime_input_name(spec)
        if haskey(inputs, name)
            T = _runtime_input_type(spec)
            value = getproperty(inputs, name)
            value isa T || error("Runtime input `$name` has type $(typeof(value)), expected `$T`.")
        elseif _runtime_input_required(spec)
            error("Missing required runtime input `$name`.")
        end
    end

    return merge(_runtime_input_defaults(specs), inputs)
end

"""
    with_inputs(lc, plan, inputs)

Returns `lc`, the `LoopContext` a new run starts from (`make_loop_context`), with the run's inputs added to its runtime
context as `_inputs`, after checking them against `plan`'s `@input` declarations (`_validate_runtime_inputs`). Every
`prepare_for_loop` method for a new run calls it. Returns `lc` itself when the plan declares no inputs and none were
passed.
"""
@inline function with_inputs(lc::LC, plan::A, inputs::I) where {LC<:LoopContext, A, I<:NamedTuple}
    checked = _validate_runtime_inputs(plan, inputs)
    isempty(checked) && return lc
    runtime = @inline with_subcontext((@inline getruntime(lc)), Val(:_inputs), SubContext{:_inputs}(checked))
    return LoopContext((@inline getpersistent(lc)), runtime)
end
