"""
A lifecycle input or override is resolved when its target parameter is the
context namespace symbol.

It specifies variables with names and values that target a namespace
The resolver takes an Override or Input that either targets a namespace directly
or a process entity and returns the same kind of object with the target changed
to the resolved namespace symbol.
"""
@inline _retarget_input(::Init{Target,NT,Ref}, name) where {Target,NT,Ref} = Init{name,NT,Nothing}
@inline _retarget_input(::Override{Target,NT,Ref}, name) where {Target,NT,Ref} = Override{name,NT,Nothing}
@inline _retarget_input(::Interactive{Target,Names,Ref}, name) where {Target,Names,Ref} = Interactive{name,Names,Nothing}
@inline retarget(ov::Union{Init, Override}, name) = _retarget_input(ov, name)(get_vars(ov), nothing)
@inline retarget(spec::Interactive, name) = _retarget_input(spec, name)(nothing)

@inline get_target(::Union{Init{Target}, Override{Target}, Interactive{Target}}) where {Target} = Target
@inline get_target(::Type{<:Union{Init{Target}, Override{Target}, Interactive{Target}}}) where {Target} = Target
@inline get_ref(ov::OI) where {OI<:InputInterface} = ov.ref
@inline get_vars(ov::OI) where {OI<:Union{Override, Input}} = ov.vars

@inline get_target_name(ov::InputInterface) = get_target(ov)

@inline _resolve_input_target_key(reg::NameSpaceRegistry, target) = static_findkey(reg, target)
@inline _resolve_input_target_key(reg::NameSpaceRegistry, matcher::AbstractMatcher) = getkey(get_by_matcher(reg, matcher))

"""Resolve one lifecycle input/override against the loop algorithm registry."""
@inline function resolve(cla::LA, ov::OI) where {LA<:AbstractLoopAlgorithm, OI<:InputInterface}
    return resolve(getregistry(cla), ov)
end

@inline resolve(reg::R, ovs::Tuple) where {R<:NameSpaceRegistry} = flat_collect_broadcast(ovs) do o
    resolve(reg, o)
end

@inline function resolve(reg::R, ov::OI) where {R<:NameSpaceRegistry, OI<:InputInterface}
    target = get_target(ov)
    if target isa Symbol
        @assert haskey(reg, target) "Target algorithm $(target) not found in registry: $reg \n Cannot resolve lifecycle target."
        return (retarget(ov, target),)
    elseif target isa Tuple #i.e. multiple targets for same variables
        duplicated_ovs = map(t -> retarget(ov, t), target)
        return resolve(reg, duplicated_ovs)
    end

    key = _resolve_input_target_key(reg, target)
    if isnothing(key)
        error("Target algorithm $(target) not found in registry: $reg \n Cannot resolve lifecycle target.")
    end
    return (retarget(ov, key),)
end

@inline resolve(cla::LA, ovs::Tuple) where {LA<:AbstractLoopAlgorithm} = flat_collect_broadcast(ovs) do ov
    resolve(cla, ov)
end

"""
Resolve a targetless `Init` into one resolved `Init` per registered namespace.
"""
@inline function resolve(reg::R, init::I) where {R<:NameSpaceRegistry, I<:Init{AllInitTargets}}
    vars = get_vars(init)

    # After this point the init pipeline can use the ordinary target-specific
    # merge path, so all-target init does not need special cases downstream.
    return map(name -> Init{name, typeof(vars), Nothing}(vars, nothing), keys(reg))
end

"""
Termination
"""
resolve(::Any) = ()

"""
From resolved inputs and overrides construct NamedTuples for merging into
ProcessContext.
"""
@inline function construct_context_merge_tuples(named_overrides_inputs; to_all::TA = (;)) where {TA}
    if isempty(named_overrides_inputs)
        return (;)
    end
    for input in named_overrides_inputs
        isresolved(input) || error("Expected resolved lifecycle input/override with a Symbol target, got target $(get_target(input)).")
    end
    names = map(o -> get_target_name(o), named_overrides_inputs) # Get the names from the registry
    vars = get_vars.(named_overrides_inputs) # Get the input variables
    if !isempty(to_all) # Add common variables to all named tuples
        vars = merge.(vars, Ref(to_all))
    end
    return NamedTuple{tuple(names...)}(vars)
end

"""
Merge resolved overrides and inputs into a ProcessContext.
"""
@inline function merge_resolved_inputs(context::C, overrides_or_inputs; to_all::TA = (;)) where {C<:ProcessContext, TA}
    if isempty(overrides_or_inputs)
        return context
    end
    override_nt = @inline construct_context_merge_tuples(overrides_or_inputs; to_all = to_all)
    @inline merge_into_subcontexts(context, override_nt)
end

@inline function Base.merge(context::C, overrides_or_inputs::Vararg{Union{Override, Input},N}; to_all::TA = (;)) where {C<:ProcessContext, N, TA}
    return @inline merge_resolved_inputs(context, overrides_or_inputs; to_all = to_all)
end
