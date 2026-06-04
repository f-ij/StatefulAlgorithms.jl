export Interactive, InteractiveVar

"""
    InteractiveVar(x)

Mutable storage for an init-time interactive context variable.

Algorithms read the stored value through `SubContextView`, while external code
can mutate the value with `ref[] = value` without changing context shape.
"""
mutable struct InteractiveVar{T}
    x::T
end

"""Return the current value stored in an `InteractiveVar`."""
@inline Base.getindex(ref::InteractiveVar{T}) where {T} = getfield(ref, :x)::T

"""Update an `InteractiveVar`, preserving its original value type."""
@inline function Base.setindex!(ref::InteractiveVar{T}, value) where {T}
    setfield!(ref, :x, convert(T, value))
    return ref[]
end

"""
    Interactive(target, varnames...)

Lifecycle option that wraps named target variables in `InteractiveVar` after
`init` and `Override` values have been applied.
"""
struct Interactive{Target, Names, Ref} <: InputInterface
    ref::Ref
end

function Interactive(target, varnames::Symbol...)
    isempty(varnames) && error("Interactive requires at least one variable name.")
    return Interactive{_input_target_parameter(target), varnames, typeof(target)}(target)
end

@inline Interactive{Target, Names}(ref = nothing) where {Target, Names} =
    Interactive{Target, Names, typeof(ref)}(ref)

@inline target_type(::Interactive{Target}) where {Target} = Target

@inline interactive_names(::Union{Interactive{Target, Names}, Type{<:Interactive{Target, Names}}}) where {Target, Names} = Names

"""Expose the current interactive payload when a `SubContextView` reads it."""
@inline subcontext_view_value(ref::InteractiveVar) = ref[]

"""Wrap a context value for interactive mutation, unless it is already wrapped."""
@inline interactive_wrapper(value) = InteractiveVar(value)
@inline interactive_wrapper(ref::InteractiveVar) = ref

"""Write an algorithm return value through an existing `InteractiveVar`."""
@inline function subcontext_writeback_value(ref::InteractiveVar, value)
    ref[] = value
    return ref
end

"""
    apply_interactive_specs(context, specs)

Wrap every variable named by resolved `Interactive` lifecycle specs in the
prepared context.
"""
@inline @generated function apply_interactive_specs(context::C, specs::Specs) where {C<:ProcessContext, Specs<:Tuple}
    exprs = Any[:(interactive_context = context)]
    for (idx, spec_type) in enumerate(Specs.parameters)
        spec_type <: Interactive || continue
        target = get_target(spec_type)
        names = interactive_names(spec_type)
        push!(
            exprs,
            :(interactive_context = @inline _wrap_interactive_subcontext(
                interactive_context,
                Val($(QuoteNode(target))),
                Val($(QuoteNode(names))),
            )),
        )
    end
    push!(exprs, :(return interactive_context))
    return Expr(:block, exprs...)
end

"""
Wrap selected variables in one subcontext with `InteractiveVar`.
"""
@inline @generated function _wrap_interactive_subcontext(context::C, ::Val{subcontext}, ::Val{Names}) where {C<:ProcessContext, subcontext, Names}
    subcontext_names = fieldnames(C.parameters[1])
    subcontext in subcontext_names || error("Interactive target $(subcontext) not found in context. Available subcontexts are: $(subcontext_names).")
    data_type = getdatatype(fieldtype(C.parameters[1], subcontext))
    data_names = fieldnames(data_type)
    for name in Names
        name in data_names || error("Interactive variable $(subcontext).$(name) not found. Available variables are: $(data_names).")
    end

    value_exprs = (:(@inline interactive_wrapper(getproperty(old_data, $(QuoteNode(name))))) for name in Names)
    return quote
        old_subcontext = @inline getproperty(get_subcontexts(context), $(QuoteNode(subcontext)))
        old_data = @inline getdata(old_subcontext)
        patch = NamedTuple{$Names}(($(value_exprs...),))
        return @inline merge_into_subcontext(context, Val($(QuoteNode(subcontext))), patch)
    end
end

"""
Merge resolved `Interactive` specs by target while keeping all requested names.
"""
function _merge_interactives_by_target(base::B, updates::U) where {B<:Tuple, U<:Tuple}
    isempty(base) && return updates
    isempty(updates) && return base

    merged = collect(Any, base)
    for update in updates
        target = get_target_name(update)
        idx = findfirst(spec -> get_target_name(spec) == target, merged)
        if isnothing(idx)
            push!(merged, update)
        else
            old_names = interactive_names(merged[idx])
            new_names = interactive_names(update)
            combined = (old_names..., (name for name in new_names if !(name in old_names))...)
            merged[idx] = Interactive{target, combined, typeof(get_ref(update))}(get_ref(update))
        end
    end
    return Tuple(merged)
end

@inline _split_override_interactive(specs) = filter_by_type(Override, specs), filter_by_type(Interactive, specs)

"""Split lifecycle specs into init, override, and interactive phases."""
function _split_lifecycle_specs(specs)
    inits, overrides = _split_init_override(specs)
    interactives = filter_by_type(Interactive, specs)
    return inits, overrides, interactives
end
