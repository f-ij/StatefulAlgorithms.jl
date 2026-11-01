#=
The runtime context of a loop: a `ProcessContext` whose subcontexts are runtime context partitions (`RuntimePartition`),
each under its partition name: captured returns, subcontext returns, declared locals and inputs. A runtime context only
has the partitions it uses.
=#

############################################################################################
# 1. Reading a partition
############################################################################################

"""
    get_runtime_values(runtime_context, partition)

Return the values a runtime context holds for `partition`, as a named tuple: the contents of a runtime context partition
(e.g. its inputs), or for a namespace what its algorithm returned this step besides its state. Empty when there are none.
"""
function get_runtime_values end

@inline function get_runtime_values(pc::ProcessContext, ::RuntimePartition{name}) where {name}
    subcontexts = @inline get_subcontexts(pc)
    return haskey(subcontexts, name) ? getdata(getproperty(subcontexts, name)) : (;)
end

@inline function get_runtime_values(pc::ProcessContext, ::StatePartition{name}) where {name}
    returns = @inline get_subcontext_returns(pc)
    return haskey(returns, name) ? getproperty(returns, name) : (;)
end

"""Return the captured returns in a runtime context: what statements (`y = f(x)`, calls) returned this step."""
@inline get_captured_returns(pc::ProcessContext) = @inline get_runtime_values(pc, RuntimePartition{:_captured_returns}())

@inline get_captured_returns(pc::ProcessContext, name::Symbol) = getproperty(get_captured_returns(pc), name)

"""Return the runtime inputs in a runtime context."""
@inline get_inputs(pc::ProcessContext) = @inline get_runtime_values(pc, RuntimePartition{:_inputs}())

@inline get_inputs(pc::ProcessContext, name::Symbol) = getproperty(get_inputs(pc), name)

"""
Return the subcontext returns in a runtime context: per namespace, what its algorithm returned this step that is not its
state, as `(; Sensor_1 = (; extra = ...), ...)`.
"""
@inline get_subcontext_returns(pc::ProcessContext) = @inline get_runtime_values(pc, RuntimePartition{:_subcontext_returns}())

"""Return the declared loop-local variables (`Local`) held in a runtime or paused context."""
@inline get_declared_locals(pc::ProcessContext) = @inline get_runtime_values(pc, RuntimePartition{:_declared_locals}())

############################################################################################
# 2. Writing step returns
############################################################################################

"""
Return `pc` with values merged into its captured returns.
"""
@inline function _merge_into_captured_returns(pc::ProcessContext, args::NamedTuple)
    runtime = @inline merge(get_captured_returns(pc), args)
    return @inline with_subcontext(pc, Val(:_captured_returns), SubContext{:_captured_returns}(runtime))
end

"""
    merge_runtime_return(runtime_context, partition, returns)

Return `runtime_context` with `returns`, a step's returns for the partition `partition`, written into the runtime
context: captured returns, declared locals, or for a namespace's partition its subcontext returns.
"""
function merge_runtime_return end

"""A namespace's subcontext returns (`owner` is its key): stored under it in `_subcontext_returns`."""
@inline function merge_runtime_return(runtime_context::C, ::StatePartition{owner}, args::A) where {C<:ProcessContext,owner,A<:NamedTuple}
    returns = @inline get_subcontext_returns(runtime_context)
    old_data = haskey(returns, owner) ? getproperty(returns, owner) : (;)
    new_returns = @inline merge(returns, NamedTuple{(owner,)}(((@inline merge(old_data, args)),)))
    return @inline with_subcontext(runtime_context, Val(:_subcontext_returns), SubContext{:_subcontext_returns}(new_returns))
end

"""Captured returns (what statements and calls return)."""
@inline merge_runtime_return(runtime_context::C, ::RuntimePartition{:_captured_returns}, args::A) where {C<:ProcessContext,A<:NamedTuple} =
    @inline _merge_into_captured_returns(runtime_context, args)

"""Declared locals: each written as `_write_locals` says (a placeholder is replaced, a typed local converts)."""
@inline function merge_runtime_return(runtime_context::C, ::RuntimePartition{:_declared_locals}, args::A) where {C<:ProcessContext,A<:NamedTuple}
    locals = @inline _write_locals(get_declared_locals(runtime_context), args)
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
                $(context_partition(name)),
                getproperty(args, $(QuoteNode(name))),
            )),
        )
    end
    push!(exprs, :(return merged_runtime))
    return Expr(:block, exprs...)
end
