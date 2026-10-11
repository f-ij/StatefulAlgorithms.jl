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

"""Return a context containing one named subcontext."""
@inline _single_subcontext_context(::Val{name}, data::D) where {name,D<:NamedTuple} =
    ProcessContext(NamedTuple{(name,)}((SubContext{name}(data),)), nothing)

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
    error("Context has no persistent subcontext named `$name`.")
end

@inline Base.propertynames(pc::ProcessContext, private::Bool = false) = propertynames(@inline get_subcontexts(pc))

@inline Base.@constprop :aggressive function Base.getindex(pc::ProcessContext, name::Symbol)
    return @inline _getindex_part(context_part(Val(name)), pc, name)
end

# `pc[:_captured_returns]` and `pc[:_inputs]` give that part's values; any other name its subcontext.
@inline _getindex_part(::ContextPart, pc::ProcessContext, name::Symbol) = @inline getproperty(pc, name)
@inline _getindex_part(part::Union{CapturedReturns, Inputs}, pc::ProcessContext, name::Symbol) = @inline get_part_data(pc, part)

@inline function Base.getindex(pc::ProcessContext, obj)
    reg = getregistry(pc)
    isnothing(reg) && error("Cannot index a runtime ProcessContext by object because it has no registry.")
    name = getkey(reg[obj])
    return @inline getproperty(pc, name)
end

@inline Base.getindex(pc::ProcessContext, idx::Int) = get_subcontexts(pc)[idx]

@inline get_subcontexts(pc::ProcessContext) = getfield(pc, :subcontexts)
"""Registry field as stored: a `Ref` to the registry, or `nothing`. Rebuilds pass this through."""
@inline registryref(pc::ProcessContext) = getfield(pc, :reg)
@inline getregistry(pc::ProcessContext) = _unref(registryref(pc))
@inline _unref(ref::Base.RefValue) = ref[]
@inline _unref(::Nothing) = nothing

"""Registry type of a context (value or type), with the `Ref` box unwrapped."""
@inline getregistrytype(::Type{<:ProcessContext{D,Base.RefValue{R}}}) where {D,R} = R
@inline getregistrytype(::Type{<:ProcessContext{D,Nothing}}) where {D} = Nothing
@inline getregistrytype(pc::ProcessContext) = getregistrytype(typeof(pc))

"""The values of a runtime part in a runtime context, as a named tuple; empty when the context has no such part."""
@inline function get_part_data(pc::ProcessContext, part::ContextPart)
    subcontexts = @inline get_subcontexts(pc)
    return haskey(subcontexts, part_name(part)) ? getdata(getproperty(subcontexts, part_name(part))) : (;)
end

"""The captured returns in a runtime context: what statements (`y = f(x)`, calls) returned this step."""
@inline get_captured_returns(pc::ProcessContext) = @inline get_part_data(pc, CapturedReturns())

@inline get_captured_returns(pc::ProcessContext, name::Symbol) = getproperty(get_captured_returns(pc), name)

"""Return the runtime-input bucket stored in a runtime context."""
@inline get_inputs(pc::ProcessContext) = @inline get_part_data(pc, Inputs())

@inline get_inputs(pc::ProcessContext, name::Symbol) = getproperty(get_inputs(pc), name)

"""
The subcontext returns in a runtime context: per namespace, what its algorithm returned this step that is not its
state, as `(; Sensor_1 = (; extra = ...), ...)`.
"""
@inline get_subcontext_returns(pc::ProcessContext) = @inline get_part_data(pc, SubcontextReturns())

"""Return the declared loop-local variables (`Local`) held in a runtime or paused context."""
@inline get_declared_locals(pc::ProcessContext) = @inline get_part_data(pc, DeclaredLocals())

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
    return ProcessContext(subcontexts, registryref(pc))
end

"""A runtime part as `(name, data expression)` pairs for the final projection: subcontext returns per namespace."""
_final_parts(::ContextPart, name::Symbol, ::Type) = [(name, :(getdata(getproperty(runtime_subcontexts, $(QuoteNode(name))))))]
_final_parts(::CapturedReturns, name::Symbol, ::Type) = [(name, :(map(_final_value, getdata(getproperty(runtime_subcontexts, $(QuoteNode(name)))))))]
_final_parts(part::SubcontextReturns, name::Symbol, ::Type{T}) where {T} =
    [(owner, :(map(_final_value, getproperty(getdata(getproperty(runtime_subcontexts, $(QuoteNode(name)))), $(QuoteNode(owner)))))) for owner in fieldnames(T)]

"""
    visible_context(lc::LoopContext)   (ContextBundles.jl)

Everything a loop holds at its end, as one `ProcessContext` to read from: the persistent subcontexts with each namespace's
subcontext returns merged in, and the runtime parts (captured returns, inputs, declared locals) as subcontexts. A return
shows the value of the last step that wrote it, or `nothing`. What `finalstep`
gets. Only a projection: the persistent context stays what the loop stores.
"""
@inline @generated function _visible_context(context::C, runtime_context::RC) where {C<:ProcessContext,RC<:ProcessContext}
    state_names = fieldnames(C.parameters[1])
    runtime_names = fieldnames(RC.parameters[1])
    isempty(runtime_names) && return :(context)

    exprs = Any[
        :(subcontexts = @inline get_subcontexts(context)),
        :(runtime_subcontexts = @inline get_subcontexts(runtime_context)),
    ]

    # Each runtime part as (name, data): a namespace's subcontext returns are shown in that namespace.
    parts = Any[]
    for name in runtime_names
        append!(parts, _final_parts(context_part(Val(name)), name, getdatatype(fieldtype(RC.parameters[1], name))))
    end

    for (name, data_expr) in parts
        if name in state_names
            push!(
                exprs,
                quote
                    old_subcontext = @inline getproperty(subcontexts, $(QuoteNode(name)))
                    final_data = @inline merge(getdata(old_subcontext), $data_expr)
                    final_subcontext = @inline withdata(old_subcontext, final_data)
                    subcontexts = @inline replace_namedtuple_field(subcontexts, Val($(QuoteNode(name))), final_subcontext)
                end,
            )
        else
            push!(
                exprs,
                quote
                    subcontexts = @inline merge(subcontexts, NamedTuple{$((name,))}((SubContext{$(QuoteNode(name))}($data_expr),)))
                end,
            )
        end
    end

    push!(exprs, :(return ProcessContext(subcontexts, registryref(context))))
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
Merge values into the captured returns of a runtime context.
"""
@inline function _merge_into_captured_returns(pc::ProcessContext, args::NamedTuple)
    runtime = @inline _merge_slots(get_captured_returns(pc), args)
    return @inline with_subcontext(pc, Val(:_captured_returns), SubContext{:_captured_returns}(runtime))
end

"""
    merge_runtime_return(runtime_context, Val(owner), returns)

`runtime_context` with `returns`, a step's returns for `owner`, written into the part `owner` names: captured returns,
declared locals, or (any other `owner`, a namespace) its subcontext returns. Nothing returned leaves it as it is.
"""
@inline function merge_runtime_return(runtime_context::C, ::Val{owner}, ::Nothing) where {C<:ProcessContext,owner}
    return runtime_context
end

"""A namespace's subcontext returns (`owner` is its key): stored under it in `_subcontext_returns`."""
@inline function merge_runtime_return(runtime_context::C, ::Val{owner}, args::A) where {C<:ProcessContext,owner,A<:NamedTuple}
    returns = @inline get_subcontext_returns(runtime_context)
    old_data = haskey(returns, owner) ? getproperty(returns, owner) : (;)
    new_returns = @inline merge(returns, NamedTuple{(owner,)}(((@inline _merge_slots(old_data, args)),)))
    return @inline with_subcontext(runtime_context, Val(:_subcontext_returns), SubContext{:_subcontext_returns}(new_returns))
end

"""Captured returns (what statements and calls return)."""
@inline merge_runtime_return(runtime_context::C, ::Val{:_captured_returns}, args::A) where {C<:ProcessContext,A<:NamedTuple} =
    @inline _merge_into_captured_returns(runtime_context, args)

"""Declared locals keep their declared field types when written."""
@inline function merge_runtime_return(runtime_context::C, ::Val{:_declared_locals}, args::A) where {C<:ProcessContext,A<:NamedTuple}
    locals = @inline _merge_declared(get_declared_locals(runtime_context), args)
    return @inline with_subcontext(runtime_context, Val(:_declared_locals), SubContext{:_declared_locals}(locals))
end

@inline function merge_runtime_return(runtime_context::C, ::Val{owner}, args::A, demand::ReturnDemand{Names}) where {C<:ProcessContext,owner,A<:NamedTuple,Names}
    return @inline merge_runtime_return(runtime_context, Val(owner), _demanded_namedtuple(args, demand))
end

@inline function merge_runtime_return(runtime_context::C, ::Val{owner}, ::Nothing, demand::ReturnDemand) where {C<:ProcessContext,owner}
    return runtime_context
end

"""Filter a named tuple to the fields demanded by downstream runtime consumers."""
@inline _demanded_namedtuple(args::A, ::ReturnDemand{:all}) where {A<:NamedTuple} = args

@inline @generated function _demanded_namedtuple(args::A, ::ReturnDemand{Names}) where {A<:NamedTuple,Names}
    kept = tuple((name for name in fieldnames(A) if name in Names)...)
    exprs = (:(getproperty(args, $(QuoteNode(name)))) for name in kept)
    return :(NamedTuple{$kept}(($(exprs...),)))
end

"""`runtime_context` with the returns of several owners written in, `args` holding `owner = returns` (see `merge_runtime_return`)."""
@inline @generated function merge_runtime_returns(runtime_context::C, args::As) where {C<:ProcessContext,As<:NamedTuple}
    names = fieldnames(As)
    isempty(names) && return :(runtime_context)

    exprs = Any[:(merged_runtime = runtime_context)]
    for name in names
        push!(
            exprs,
            :(merged_runtime = @inline merge_runtime_return(
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
