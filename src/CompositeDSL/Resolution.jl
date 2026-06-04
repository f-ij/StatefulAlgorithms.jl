"""Internal resolved representation used while expanding the DSL."""
struct _CompositeDSLResolved{Kind, Entity, Inputs}
    entity::Entity
    inputs::Inputs
end

"""ProcessAlgorithm direct-call metadata used by the DSL."""
@inline _dsl_processalgorithm_positional_names(::Type{<:ProcessAlgorithm}) = ()
@inline _dsl_processalgorithm_positional_names(algo::ProcessAlgorithm) = _dsl_processalgorithm_positional_names(typeof(algo))

"""The DSL preserves the identity the user supplied instead of uniquifying it."""
@inline _dsl_with_customname(algo, ::Val{Symbol()}) = algo
@inline _dsl_with_customname(algo, ::Val{Name}) where {Name} = algo

"""Resolve direct-call DSL syntax for a `ProcessAlgorithm` using its declared positional names."""
function _resolve_composite_dsl_algorithm_call(
    spec,
    keyword_args::NamedTuple,
    input_symbols::Tuple{Vararg{Symbol}},
    ::Val{Name},
) where {Name}
    positional_names = _dsl_processalgorithm_positional_names(spec)
    length(input_symbols) <= length(positional_names) || error("Too many positional DSL inputs for `$spec`. Expected at most $(length(positional_names)), got $(length(input_symbols)).")

    resolved = _dsl_with_customname(spec, Val(Name))
    inputs = Any[
        (; kind = :simple, source = input_symbols[idx], destination = positional_names[idx])
        for idx in eachindex(input_symbols)
    ]

    for destination in keys(keyword_args)
        source = getproperty(keyword_args, destination)
        source isa Symbol || error("Keyword arguments in direct ProcessAlgorithm call syntax must be routed symbols. Use `Algo(name = source)` for route syntax or plain function call syntax for literal keyword captures.")
        push!(inputs, (; kind = :simple, source, destination))
    end

    routed_inputs = tuple(inputs...)
    return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
end

"""Retarget one direct-call ProcessAlgorithm route onto the declared argument name."""
function _dsl_retarget_processalgorithm_direct_input(input, destination::Symbol)
    if input.kind == :simple
        return (; kind = :simple, source = input.source, destination)
    elseif input.kind == :context_simple
        return (; kind = :context_simple, owner = input.owner, source = input.source, destination)
    elseif input.kind == :simple_transform
        return (; kind = :simple_transform, source = input.source, destination, transform_expr = input.transform_expr)
    elseif input.kind == :context_transform
        return (; kind = :context_transform, owner = input.owner, source = input.source, destination, transform_expr = input.transform_expr)
    end

    error("Unsupported direct-call DSL input kind `$(input.kind)`.")
end

"""Resolve one non-function DSL entity into the internal representation used by the block builder."""
function _resolve_composite_dsl_entity(spec, inputs::Tuple, output_symbols::Tuple{Vararg{Symbol}}, ::Val{Name}) where {Name}
    if spec isa Union{ProcessState, Type{<:ProcessState}}
        # States participate in the block like algorithms, but they do not accept
        # routed inputs through this syntax.
        isempty(inputs) || error("ProcessStates in the DSL cannot declare routed inputs.")
        return _CompositeDSLResolved{:state, typeof(spec), typeof(inputs)}(spec, inputs)
    elseif spec isa AbstractIdentifiableAlgo
        # Already-named/unique algorithms can pass straight through.
        return _CompositeDSLResolved{:algo, typeof(spec), typeof(inputs)}(spec, inputs)
    elseif spec isa Union{SteppableAlgorithm, Type{<:SteppableAlgorithm}}
        # Plain algorithms/loop algorithms are passed through and keyed by the
        # normal constructor surface later.
        resolved = _dsl_with_customname(spec, Val(Name))
        return _CompositeDSLResolved{:algo, typeof(resolved), typeof(inputs)}(resolved, inputs)
    elseif spec isa Function
        # Bare functions are wrapped so the rest of the system can treat them like
        # normal algorithms with routed inputs/outputs.
        isempty(inputs) || error("Plain functions should use regular call syntax in the DSL, e.g. `f(x)` or `f(x; scale = 2)`.")
        wrapped = FuncWrapper(spec, (), output_symbols)
        resolved = _dsl_with_customname(wrapped, Val(Name))
        return _CompositeDSLResolved{:algo, typeof(resolved), typeof(inputs)}(resolved, inputs)
    else
        error("Unsupported DSL entry `$spec`. Expected a SteppableAlgorithm, ProcessState, or Function.")
    end
end

"""Resolve direct-call DSL syntax for either a `ProcessAlgorithm` or a plain Julia function."""
function _resolve_composite_dsl_call(
    spec,
    keyword_args::NamedTuple,
    positional_values::Tuple,
    display_positional_values::Tuple,
    display_keyword_args::NamedTuple,
    output_symbols::Tuple{Vararg{Symbol}},
    routed_positional_inputs::Tuple,
    routed_keyword_inputs::Tuple,
    ::Val{Name},
) where {Name}
    if spec isa Union{ProcessAlgorithm, Type{<:ProcessAlgorithm}}
        positional_names = _dsl_processalgorithm_positional_names(spec)
        length(routed_positional_inputs) <= length(positional_names) || error("Too many positional DSL inputs for `$spec`. Expected at most $(length(positional_names)), got $(length(routed_positional_inputs)).")

        resolved = _dsl_with_customname(spec, Val(Name))
        inputs = Any[
            _dsl_retarget_processalgorithm_direct_input(routed_positional_inputs[idx], positional_names[idx])
            for idx in eachindex(routed_positional_inputs)
        ]

        for destination in keys(keyword_args)
            source = getproperty(keyword_args, destination)
            routed = findfirst(input -> input.destination == destination, routed_keyword_inputs)
            if isnothing(routed)
                source isa Symbol || error("Direct-call DSL syntax for ProcessAlgorithms only supports routed symbol keyword arguments.")
                push!(inputs, (; kind = :simple, source, destination))
                continue
            end

            input = routed_keyword_inputs[routed]
            if input.kind == :simple
                push!(inputs, (; kind = :simple, source = input.source, destination))
            elseif input.kind == :context_simple
                push!(inputs, (; kind = :context_simple, owner = input.owner, source = input.source, destination))
            elseif input.kind == :simple_transform
                push!(inputs, (; kind = :simple_transform, source = input.source, destination, transform_expr = input.transform_expr))
            elseif input.kind == :context_transform
                push!(inputs, (; kind = :context_transform, owner = input.owner, source = input.source, destination, transform_expr = input.transform_expr))
            else
                error("Unsupported direct-call DSL keyword input kind `$(input.kind)`.")
            end
        end

        routed_inputs = tuple(inputs...)
        return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
    end

    spec isa Function || error("Direct-call DSL syntax requires either a plain function or a ProcessAlgorithm. Got `$spec`.")

    # FuncWrapper handles the runtime call; the DSL only has to recover how the
    # wrapper should receive its routed inputs.
    wrapped = FuncWrapper(spec, positional_values, output_symbols, keyword_args, display_positional_values, display_keyword_args)
    resolved = _dsl_with_customname(wrapped, Val(Name))

    inputs = Any[routed_positional_inputs...]
    append!(inputs, routed_keyword_inputs)
    routed_inputs = tuple(inputs...)
    return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
end

"""Resolve keyword-only DSL call syntax at runtime without macro-time type inspection."""
function _resolve_composite_dsl_keyword_call(
    spec,
    keyword_args::NamedTuple,
    display_keyword_args::NamedTuple,
    routed_inputs::Tuple,
    output_symbols::Tuple{Vararg{Symbol}},
    ::Val{Name},
) where {Name}
    if spec isa Function
        wrapped = FuncWrapper(spec, (), output_symbols, keyword_args, (), display_keyword_args)
        resolved = _dsl_with_customname(wrapped, Val(Name))
        return _CompositeDSLResolved{:algo, typeof(resolved), typeof(routed_inputs)}(resolved, routed_inputs)
    end

    return _resolve_composite_dsl_entity(spec, routed_inputs, output_symbols, Val(Name))
end

"""Rewrite DSL alias references inside expressions while preserving routed symbols."""
function _dsl_rewrite_alias_expr(alias_map, ex, protected_symbols::Set{Symbol})
    if ex isa Symbol
        if ex in protected_symbols || !haskey(alias_map, ex)
            return ex
        end
        return alias_map[ex]
    elseif ex isa Expr
        if ex.head == :kw
            return Expr(:kw, ex.args[1], _dsl_rewrite_alias_expr(alias_map, ex.args[2], protected_symbols))
        elseif ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
            return Expr(:., _dsl_rewrite_alias_expr(alias_map, ex.args[1], protected_symbols), ex.args[2])
        end
        return Expr(ex.head, map(arg -> _dsl_rewrite_alias_expr(alias_map, arg, protected_symbols), ex.args)...)
    end
    return ex
end
