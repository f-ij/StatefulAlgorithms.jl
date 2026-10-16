#=
The runtime context of a loop: a `ProcessContext` whose subcontexts are runtime context partitions (ContextPartitions.jl),
each under its partition name: captured returns, subcontext returns, declared locals and inputs. A runtime context only
has the partitions it uses.
=#

############################################################################################
# 1. Reading a partition
############################################################################################

"""Return the values in one partition of a runtime context (e.g. its inputs) as a named tuple; empty when the runtime context does not have that partition."""
@inline function get_runtime_partition(pc::ProcessContext, partition::RuntimePartition)
    subcontexts = @inline get_subcontexts(pc)
    name = runtime_partition_name(partition)
    return haskey(subcontexts, name) ? getdata(getproperty(subcontexts, name)) : (;)
end

"""Return the captured returns in a runtime context: what statements (`y = f(x)`, calls) returned this step."""
@inline get_captured_returns(pc::ProcessContext) = @inline get_runtime_partition(pc, CapturedReturns())

@inline get_captured_returns(pc::ProcessContext, name::Symbol) = getproperty(get_captured_returns(pc), name)

"""Return the runtime inputs in a runtime context."""
@inline get_inputs(pc::ProcessContext) = @inline get_runtime_partition(pc, Inputs())

@inline get_inputs(pc::ProcessContext, name::Symbol) = getproperty(get_inputs(pc), name)

"""
Return the subcontext returns in a runtime context: per namespace, what its algorithm returned this step that is not its
state, as `(; Sensor_1 = (; extra = ...), ...)`.
"""
@inline get_subcontext_returns(pc::ProcessContext) = @inline get_runtime_partition(pc, SubcontextReturns())

"""Return the declared loop-local variables (`Local`) held in a runtime or paused context."""
@inline get_declared_locals(pc::ProcessContext) = @inline get_runtime_partition(pc, DeclaredLocals())

############################################################################################
# 2. Writing step returns
############################################################################################

"""
Return `pc` with values merged into its captured returns.
"""
@inline function _merge_into_captured_returns(pc::ProcessContext, args::NamedTuple)
    runtime = @inline _merge_slots(get_captured_returns(pc), args)
    return @inline with_subcontext(pc, Val(:_captured_returns), SubContext{:_captured_returns}(runtime))
end

"""
    merge_runtime_return(runtime_context, Val(owner), returns)

Return `runtime_context` with `returns`, a step's returns for `owner`, written into the runtime context partition `owner`
names: captured returns, declared locals, or (any other `owner`, a namespace) its subcontext returns. Nothing returned
leaves it as it is.
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

"""Return `runtime_context` with the returns of several owners written in, `args` holding `owner = returns` (see `merge_runtime_return`)."""
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
