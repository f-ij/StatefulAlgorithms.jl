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
    @assert R <: Union{AbstractRegistry,Nothing} "Registry type must be `Nothing` or a subtype of AbstractRegistry, got: $R"
    return :(ProcessContext{D,R}(subcontexts, reg))
end

@inline _empty_context() = ProcessContext((;), nothing)

"""Return a context containing one named subcontext."""
@inline _single_subcontext_context(::Val{name}, data::D) where {name,D<:NamedTuple} =
    ProcessContext(NamedTuple{(name,)}((SubContext(name, data),)), nothing)

@inline Base.@constprop :aggressive function Base.getproperty(pc::ProcessContext, name::Symbol)
    subcontexts = @inline get_subcontexts(pc)
    if haskey(subcontexts, name)
        return @inline getproperty(subcontexts, name)
    end
    globals = @inline getglobals(pc)
    if haskey(globals, name)
        return @inline getproperty(globals, name)
    end
    input = @inline getruntimeinput(pc)
    if haskey(input, name)
        return @inline getproperty(input, name)
    end
    error("Context has no persistent subcontext named `$name`.")
end

@inline Base.propertynames(pc::ProcessContext, private::Bool = false) = propertynames(@inline get_subcontexts(pc))

@inline Base.@constprop :aggressive function Base.getindex(pc::ProcessContext, name::Symbol)
    name === :globals && return getglobals(pc)
    name === :_runtime && return getglobals(pc)
    name === :_input && return getruntimeinput(pc)
    return @inline getproperty(pc, name)
end

@inline function Base.getindex(pc::ProcessContext, obj)
    reg = getregistry(pc)
    isnothing(reg) && error("Cannot index a runtime ProcessContext by object because it has no registry.")
    name = getkey(reg[obj])
    return @inline getproperty(pc, name)
end

@inline Base.getindex(pc::ProcessContext, idx::Int) = get_subcontexts(pc)[idx]

@inline get_subcontexts(pc::ProcessContext) = getfield(pc, :subcontexts)
@inline getregistry(pc::ProcessContext) = getfield(pc, :reg)

"""Return the flat runtime-global bucket stored in a runtime context."""
@inline function getglobals(pc::ProcessContext)
    subcontexts = @inline get_subcontexts(pc)
    return haskey(subcontexts, :_runtime) ? getdata(getproperty(subcontexts, :_runtime)) : (;)
end

@inline getglobals(pc::ProcessContext, name::Symbol) = getproperty(getglobals(pc), name)

"""Return the runtime-input bucket stored in a runtime context."""
@inline function getruntimeinput(pc::ProcessContext)
    subcontexts = @inline get_subcontexts(pc)
    return haskey(subcontexts, :_input) ? getdata(getproperty(subcontexts, :_input)) : (;)
end

@inline getruntimeinput(pc::ProcessContext, name::Symbol) = getproperty(getruntimeinput(pc), name)

@inline getwidened(::ProcessContext) = (;)
@inline has_widened_var(::ProcessContext, ::Val, ::Val) = false
@inline get_widened_var(::ProcessContext, ::Val{subcontext}, ::Val{name}) where {subcontext,name} =
    error("Runtime value `$name` for `$subcontext` is not stored in widened context state.")
@inline merge_into_widened(pc::ProcessContext, ::NamedTuple) = pc
@inline materialize_widened_context(pc::ProcessContext) = pc

"""
    withsubcontexts(pc, subcontexts)

Return an immutable `ProcessContext` rebuild with updated subcontexts.
"""
@inline function withsubcontexts(pc::PC, subcontexts::D) where {PC<:ProcessContext,D<:NamedTuple}
    return ProcessContext(subcontexts, getregistry(pc))
end

"""
    final_visible_context(context, runtimecontext)

Build the one-argument finalstep projection context. Runtime owner subcontexts
and runtime globals are materialized into a fresh context for final result
projection only; the returned process state remains `context`.
"""
@inline @generated function final_visible_context(context::C, runtimecontext::RC) where {C<:ProcessContext,RC<:ProcessContext}
    state_names = fieldnames(C.parameters[1])
    runtime_names = fieldnames(RC.parameters[1])
    isempty(runtime_names) && return :(context)

    exprs = Any[
        :(subcontexts = @inline get_subcontexts(context)),
        :(runtime_subcontexts = @inline get_subcontexts(runtimecontext)),
    ]

    for name in runtime_names
        if name in state_names
            push!(
                exprs,
                quote
                    old_subcontext = @inline getproperty(subcontexts, $(QuoteNode(name)))
                    runtime_subcontext = @inline getproperty(runtime_subcontexts, $(QuoteNode(name)))
                    final_data = @inline merge(getdata(old_subcontext), getdata(runtime_subcontext))
                    final_subcontext = @inline withdata(old_subcontext, final_data)
                    subcontexts = @inline replace_namedtuple_field(subcontexts, Val($(QuoteNode(name))), final_subcontext)
                end,
            )
        else
            push!(
                exprs,
                quote
                    runtime_subcontext = @inline getproperty(runtime_subcontexts, $(QuoteNode(name)))
                    subcontexts = @inline merge(subcontexts, NamedTuple{$((name,))}((runtime_subcontext,)))
                end,
            )
        end
    end

    push!(exprs, :(return ProcessContext(subcontexts, getregistry(context))))
    return Expr(:block, exprs...)
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

@inline subcontext_names(pc::ProcessContext{D}, name::Symbol) where {D} = @inline fieldnames(typeof(getproperty(get_subcontexts(pc), name)))
@inline subcontext_type(pc::ProcessContext{D}, name::Symbol) where {D} = @inline fieldtype(typeof(get_subcontexts(pc)), name)
@inline subcontext_type(pct::Type{<:ProcessContext{D}}, name::Symbol) where {D} = fieldtype(D, name)
@inline get_subcontexts_fieldnames(pct::Type{<:ProcessContext{D}}) where {D} = fieldnames(D)

@inline subcontexts(pc::ProcessContext) = get_subcontexts(pc)

@inline function isasubcontext(pc::Type{<:ProcessContext}, v::Val{s}) where {s<:Symbol}
    subcontext_types = pc.parameters[1]
    s in fieldnames(subcontext_types) || return false
    return fieldtype(subcontext_types, s) <: SubContext
end
@inline isasubcontext(pc::ProcessContext, s::Symbol) = isasubcontext(typeof(pc), Val(s))
@inline isasubcontext(pc::Type{<:ProcessContext}, s::Symbol) = isasubcontext(pc, Val(s))

@inline get_subcontext_type(pc::Type{<:ProcessContext}, s) = fieldtype(pc.parameters[1], s)

@inline function _subcontext_fieldnames(::Type{<:ProcessContext{D}}, ::Val{name}) where {D,name}
    name in fieldnames(D) || return ()
    return fieldnames(getdatatype(fieldtype(D, name)))
end

@inline function _has_subcontext_field(::Type{PC}, ::Val{subcontext}, ::Val{name}) where {PC<:ProcessContext,subcontext,name}
    return name in _subcontext_fieldnames(PC, Val(subcontext))
end

"""
Merge runtime globals into a runtime context.
"""
@inline function _merge_into_globals(pc::ProcessContext, args::NamedTuple)
    runtime = @inline merge(getglobals(pc), args)
    return @inline with_subcontext(pc, Val(:_runtime), SubContext(:_runtime, runtime))
end

@inline merge_runtime_return(context::C, ::Nothing) where {C<:ProcessContext} = context
@inline merge_runtime_return(context::C, retval::R) where {C<:ProcessContext,R<:NamedTuple} =
    @inline _merge_into_globals(context, retval)

function merge_runtime_return(context::C, retval::R) where {C<:ProcessContext,R}
    error("Runtime-owned step returns must be named tuples or `nothing`, got $(typeof(retval)).")
end

"""Merge owner-scoped runtime returns into `runtimecontext`."""
@inline function merge_owner_runtime_return(runtimecontext::C, ::Val{owner}, ::Nothing) where {C<:ProcessContext,owner}
    return runtimecontext
end

@inline function merge_owner_runtime_return(runtimecontext::C, ::Val{owner}, args::A) where {C<:ProcessContext,owner,A<:NamedTuple}
    subcontexts = @inline get_subcontexts(runtimecontext)
    old_data = haskey(subcontexts, owner) ? getdata(getproperty(subcontexts, owner)) : (;)
    new_data = @inline merge(old_data, args)
    return @inline with_subcontext(runtimecontext, Val(owner), SubContext(owner, new_data))
end

@inline function merge_owner_runtime_return(runtimecontext::C, ::Val{owner}, args::A, demand::ReturnDemand{Names}) where {C<:ProcessContext,owner,A<:NamedTuple,Names}
    return @inline merge_owner_runtime_return(runtimecontext, Val(owner), _demanded_namedtuple(args, demand))
end

@inline function merge_owner_runtime_return(runtimecontext::C, ::Val{owner}, ::Nothing, demand::ReturnDemand) where {C<:ProcessContext,owner}
    return runtimecontext
end

"""Filter a named tuple to the fields demanded by downstream runtime consumers."""
@inline _demanded_namedtuple(args::A, ::ReturnDemand{:all}) where {A<:NamedTuple} = args

@inline @generated function _demanded_namedtuple(args::A, ::ReturnDemand{Names}) where {A<:NamedTuple,Names}
    kept = tuple((name for name in fieldnames(A) if name in Names)...)
    exprs = (:(getproperty(args, $(QuoteNode(name)))) for name in kept)
    return :(NamedTuple{$kept}(($(exprs...),)))
end

"""Merge nested owner runtime patches into `runtimecontext`."""
@inline @generated function merge_runtime_subcontexts(runtimecontext::C, args::As) where {C<:ProcessContext,As<:NamedTuple}
    names = fieldnames(As)
    isempty(names) && return :(runtimecontext)

    exprs = Any[:(merged_runtime = runtimecontext)]
    for name in names
        push!(
            exprs,
            :(merged_runtime = @inline merge_owner_runtime_return(
                merged_runtime,
                Val($(QuoteNode(name))),
                getproperty(args, $(QuoteNode(name))),
            )),
        )
    end
    push!(exprs, :(return merged_runtime))
    return Expr(:block, exprs...)
end

"""
Merge keys into subcontext by args = (;subcontextname1 = (;var1 = val1,...), ...).
All target subcontext names must already exist in the state context.
"""
@inline @generated function merge_into_subcontexts(pc::ProcessContext{D}, args::As) where {D,As}
    sc_names = fieldnames(D)
    mergenames = fieldnames(As)
    isempty(mergenames) && return :(pc)
    if length(mergenames) == 1
        mergename = first(mergenames)
        mergename in sc_names || error("Trying to merge into unknown subcontext $(QuoteNode(mergename)) in ProcessContext. Available subcontexts are: $(sc_names) and args has names: $(mergenames)")
        return :(@inline merge_into_subcontext(pc, Val($(QuoteNode(mergename))), getproperty(args, $(QuoteNode(mergename)))))
    end

    merge_exprs = Any[:(merged_context = pc)]
    for mergename in mergenames
        mergename in sc_names || error("Trying to merge into unknown subcontext $(QuoteNode(mergename)) in ProcessContext. Available subcontexts are: $(sc_names) and args has names: $(mergenames)")
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

function _namedtuple_merge_preserves_type(old_type::Type{<:NamedTuple}, new_type::Type)
    new_type <: NamedTuple || return false

    old_names = fieldnames(old_type)
    new_names = fieldnames(new_type)
    for name in new_names
        name in old_names || return false
        fieldtype(old_type, name) === fieldtype(new_type, name) || return false
    end
    return true
end

@inline @generated function merge_into_subcontext(pc::ProcessContext{D}, ::Val{name}, args::A) where {D,name,A}
    sc_names = fieldnames(D)
    name in sc_names || error("Trying to merge into unknown subcontext $(QuoteNode(name)) in ProcessContext. Available subcontexts are: $(sc_names)")
    old_sc_type = fieldtype(D, name)

    if _namedtuple_merge_preserves_type(getdatatype(old_sc_type), A)
        return quote
            $(LineNumberNode(@__LINE__, @__FILE__))
            @inline merge_into_subcontext_rebuild(pc, Val($(QuoteNode(name))), args)
        end
    end
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        @inline merge_into_subcontext_rebuild(pc, Val($(QuoteNode(name))), args)
    end
end

@inline @generated function merge_into_subcontext_rebuild(pc::ProcessContext{D}, ::Val{name}, args) where {D,name}
    sc_names = fieldnames(D)
    name in sc_names || error("Trying to merge into unknown subcontext $(QuoteNode(name)) in ProcessContext. Available subcontexts are: $(sc_names)")

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
Replace existing subcontexts in `pc`.
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
