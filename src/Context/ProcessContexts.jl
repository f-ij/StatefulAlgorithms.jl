############################################################################################
# 1. Construction
############################################################################################

"""
    ProcessContext(subcontexts, reg)

Build a process context from named `SubContext` buckets.
"""
@generated function ProcessContext(subcontexts::D, reg::R) where {D,R}
    sc_names = fieldnames(D)
    bad_names = Symbol[]
    for name in sc_names
        if !(fieldtype(D, name) <: SubContext)
            push!(bad_names, name)
        end
    end
    @assert isempty(bad_names) "All fields in ProcessContext subcontexts must be of type SubContext, but found non-SubContext fields: $bad_names"
    @assert R <: Union{AbstractRegistry,Base.RefValue{<:AbstractRegistry},Nothing} "Registry must be `Nothing`, an AbstractRegistry or a Ref to one, got: $R"
    if R <: AbstractRegistry
        # Box the registry: contexts are rebuilt every step, and a boxed registry is
        # carried as one pointer instead of being copied along with the subcontexts.
        return :(ProcessContext{D,Base.RefValue{R}}(subcontexts, Ref(reg)))
    end
    return :(ProcessContext{D,R}(subcontexts, reg))
end

@inline _empty_context() = ProcessContext((;), nothing)

############################################################################################
# 2. Reading
############################################################################################

@inline get_subcontexts(pc::ProcessContext) = getfield(pc, :subcontexts)
"""Registry field as stored: a `Ref` to the registry, or `nothing`. Rebuilds pass this through."""
@inline registryref(pc::ProcessContext) = getfield(pc, :reg)
@inline getregistry(pc::ProcessContext) = _unref(registryref(pc))
@inline _unref(ref::Base.RefValue) = ref[]
@inline _unref(::Nothing) = nothing

"""
Return the subcontext named `name`; when there is no such subcontext, the captured return, input or declared local
named `name` (a declared local as its value).
"""
@inline Base.@constprop :aggressive function Base.getproperty(pc::ProcessContext, name::Symbol)
    subcontexts = @inline get_subcontexts(pc)
    if haskey(subcontexts, name)
        return @inline getproperty(subcontexts, name)
    end
    returns = @inline get_captured_returns(pc)
    if haskey(returns, name)
        return @inline getproperty(returns, name)
    end
    input = @inline get_inputs(pc)
    if haskey(input, name)
        return @inline getproperty(input, name)
    end
    locals = @inline get_declared_locals(pc)
    if haskey(locals, name)
        return @inline _follow_reads(pc, getproperty(locals, name))   # its value, not its storage
    end
    error("Context has no persistent subcontext named `$name`.")
end

@inline Base.propertynames(pc::ProcessContext, private::Bool = false) = propertynames(@inline get_subcontexts(pc))

@inline Base.@constprop :aggressive function Base.getindex(pc::ProcessContext, name::Symbol)
    return @inline _getindex_partition(context_partition(Val(name)), pc, name)
end

# `pc[:_captured_returns]` and `pc[:_inputs]` give the values in that runtime context partition; any other name its subcontext.
@inline _getindex_partition(::ContextPartition, pc::ProcessContext, name::Symbol) = @inline getproperty(pc, name)
@inline _getindex_partition(partition::Union{CapturedReturns, Inputs}, pc::ProcessContext, name::Symbol) = @inline get_runtime_partition(pc, partition)

"""Return the subcontext of the algorithm `obj`, looked up in the registry."""
@inline function Base.getindex(pc::ProcessContext, obj)
    reg = getregistry(pc)
    isnothing(reg) && error("Cannot index a runtime ProcessContext by object because it has no registry.")
    name = getkey(reg[obj])
    return @inline getproperty(pc, name)
end

@inline Base.getindex(pc::ProcessContext, idx::Int) = get_subcontexts(pc)[idx]

############################################################################################
# 3. Type queries
############################################################################################

"""Return the names of the subcontexts in a context type."""
@inline get_subcontexts_fieldnames(::Type{<:ProcessContext{D}}) where {D} = fieldnames(D)

"""Return the type of the subcontext named `name` in a context (value or type)."""
@inline get_subcontext_type(::Type{<:ProcessContext{D}}, name::Symbol) where {D} = fieldtype(D, name)
@inline get_subcontext_type(pc::ProcessContext, name::Symbol) = get_subcontext_type(typeof(pc), name)

"""Return the variable names in the subcontext named `name` of a context (value or type)."""
@inline subcontext_fieldnames(::Type{PC}, name::Symbol) where {PC<:ProcessContext} = fieldnames(getdatatype(get_subcontext_type(PC, name)))
@inline subcontext_fieldnames(pc::ProcessContext, name::Symbol) = subcontext_fieldnames(typeof(pc), name)

############################################################################################
# 4. Rebuilding with changed subcontexts
############################################################################################

"""
    withsubcontexts(pc, subcontexts)

Return `pc` rebuilt with `subcontexts` in place of its subcontexts; the registry is kept.
"""
@inline function withsubcontexts(pc::PC, subcontexts::D) where {PC<:ProcessContext,D<:NamedTuple}
    return ProcessContext(subcontexts, registryref(pc))
end

"""Return `pc` with a named subcontext inserted or replaced."""
@inline @generated function with_subcontext(pc::PC, ::Val{name}, subcontext::SC) where {PC<:ProcessContext,name,SC<:SubContext}
    D = PC.parameters[1]
    sc_names = fieldnames(D)
    if name in sc_names
        return quote
            subcontexts = @inline get_subcontexts(pc)
            new_subcontexts = @inline replace_namedtuple_field(subcontexts, Val($(QuoteNode(name))), subcontext)
            return @inline withsubcontexts(pc, new_subcontexts)
        end
    end
    return quote
        subcontexts = @inline get_subcontexts(pc)
        new_subcontexts = @inline merge(subcontexts, NamedTuple{$((name,))}((subcontext,)))
        return @inline withsubcontexts(pc, new_subcontexts)
    end
end

_unknown_subcontext_error(name::Symbol, sc_names) =
    error("Trying to merge into unknown subcontext $(QuoteNode(name)) in ProcessContext. Available subcontexts are: $(sc_names)")

"""
Return `pc` with values merged into its subcontexts, `args` given as `(; subcontextname1 = (; var1 = val1, ...), ...)`.
All target subcontext names must already exist in `pc`.
"""
@inline @generated function merge_into_subcontexts(pc::ProcessContext{D}, args::As) where {D,As}
    sc_names = fieldnames(D)
    mergenames = fieldnames(As)
    isempty(mergenames) && return :(pc)

    merge_exprs = Any[:(merged_context = pc)]
    for mergename in mergenames
        mergename in sc_names || _unknown_subcontext_error(mergename, sc_names)
        push!(
            merge_exprs,
            :(merged_context = @inline merge_into_subcontext(
                merged_context,
                Val($(QuoteNode(mergename))),
                getproperty(args, $(QuoteNode(mergename))),
            )),
        )
    end
    push!(merge_exprs, :(return merged_context))

    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        $(merge_exprs...)
    end
end

Base.@constprop :aggressive merge_into_subcontext(pc::ProcessContext{D}, name::Symbol, args) where {D} =
    @inline merge_into_subcontext(pc, Val(name), args)

"""Return `pc` with `args` merged into its subcontext `name`, which must exist."""
@inline @generated function merge_into_subcontext(pc::ProcessContext{D}, ::Val{name}, args::A) where {D,name,A}
    sc_names = fieldnames(D)
    name in sc_names || _unknown_subcontext_error(name, sc_names)

    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        old_subcontexts = @inline get_subcontexts(pc)
        old_subcontext = @inline getproperty(old_subcontexts, $(QuoteNode(name)))
        new_subcontext = @inline merge(old_subcontext, args)
        new_subcontexts = @inline replace_namedtuple_field(old_subcontexts, Val($(QuoteNode(name))), new_subcontext)
        return @inline withsubcontexts(pc, new_subcontexts)
    end
end

"""
Return `pc` with existing subcontexts replaced, `args` given as `(; subcontextname1 = (; var1 = val1, ...), ...)`.
"""
@inline @generated function _replace_subcontexts(pc::ProcessContext{D,R}, args::As) where {D,R,As<:NamedTuple}
    sc_names = fieldnames(D)
    replacenames = fieldnames(As)
    replace_exprs = Expr[]

    for replacename in replacenames
        replacename in sc_names || error("Trying to replace unknown subcontext $(QuoteNode(replacename)) in ProcessContext. Available subcontexts are: $(sc_names) and args has names: $(replacenames)")
        push!(
            replace_exprs,
            quote
                old_subcontext = @inline getproperty(new_subcontexts, $(QuoteNode(replacename)))
                new_subcontext = @inline replace(old_subcontext, getproperty(args, $(QuoteNode(replacename))))
                new_subcontexts = @inline replace_namedtuple_field(new_subcontexts, Val($(QuoteNode(replacename))), new_subcontext)
            end,
        )
    end

    return quote
        new_subcontexts = @inline get_subcontexts(pc)
        $(replace_exprs...)
        return @inline withsubcontexts(pc, new_subcontexts)
    end
end

@inline Base.replace(pc::ProcessContext{D,R}, args::NamedTuple) where {D,R} = @inline _replace_subcontexts(pc, args)
