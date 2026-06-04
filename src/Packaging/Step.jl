@inline _package_context_seed(context) = (;)
@inline _package_context_seed(context::SubContextView) = filter_nt((; context...), :_instance)

Base.@constprop :aggressive @inline function init(pkg::Package, context::C) where {C<:AbstractContext}
    acc = _package_context_seed(context)
    state_acc = @inline unrollreplace_withargs(acc, getstates(pkg); args = (context,)) do acc, state, context
        state_ret = @inline init(state, inject(context, acc))
        isnothing(state_ret) && return acc
        return @inline merge(acc, state_ret)
    end
    return @inline unrollreplace_withargs(state_acc, getalgos(pkg); args = (context,)) do acc, func, context
        view = @inline withaliases(context, func, acc, typeof(getvaraliases(typeof(func))))
        init_ret = @inline init(getalgo(func), view)
        isnothing(init_ret) && return acc
        return @inline merge(acc, init_ret)
    end
end

Base.@constprop :aggressive @inline function step!(pkg::Package{F, S, I, A}, context::C) where {F, S, I, A, C<:AbstractContext}
    this_inc = inc(pkg)
    acc = (;)
    ret = @inline unrollreplace_withargs(acc, getalgos(pkg); args = (context, this_inc), zip = intervals(pkg)) do acc, func, context, this_inc, interval
        if @inline divides(this_inc, interval)
            view = @inline withaliases(context, func, acc, typeof(getvaraliases(typeof(func))))
            step_ret = @inline step!(getalgo(func), view)
            isnothing(step_ret) && return acc
            return @inline merge(acc, step_ret)
        end
        return acc
    end
    @inline inc!(pkg)
    return ret
end

Base.@constprop :aggressive @inline function cleanup(pkg::Package, context::C) where {C<:AbstractContext}
    acc = (;)
    ret = @inline unrollreplace_withargs(acc, getalgos(pkg); args = (context,)) do acc, func, context
        view = @inline withaliases(context, func, acc, typeof(getvaraliases(typeof(func))))
        cleanup_ret = @inline cleanup(getalgo(func), view)
        isnothing(cleanup_ret) && return acc
        return @inline merge(acc, cleanup_ret)
    end
    getinc(pkg)[] = 1
    return ret
end
