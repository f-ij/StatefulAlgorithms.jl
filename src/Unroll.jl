"""
For patterns where we have to recursively replace a value from a function apply to a list of arguments,
we can unroll the recursion with this function

f requires two arguments: the value to be replaced, and the next argument from the list
"""
# @inline function unrollreplace_splat(f::F, to_replace::C, args...) where {F, C}
#     if isempty(args)
#         return to_replace
#     end
#     first_arg = gethead(args)
#     to_replace = @inline f(to_replace, first_arg)
#     return @inline unrollreplace_splat(f, to_replace, gettail(args)...)
# end

# @inline @generated function unrollreplace_splat(f::F, to_replace::C, args...) where {F, C}
#     num_args = length(args)
#     replaceblocks = Expr(:block, (Expr(:(=), :to_replace, Expr(:call, :f, :to_replace, Expr(:call, :getindex, :args, i)) ) for i in 1:num_args)...)
#     quote
#         $(LineNumberNode(@__LINE__, @__FILE__))
#         $replaceblocks
#         to_replace
#     end
# end

@inline unrollreplace(f::F, to_replace::C, ::Tuple{}) where {F,C} = to_replace

@inline function unrollreplace(f::F, to_replace::C, args::T) where {F,C,T<:Tuple}
    # Recur through tuple head/tail instead of emitting one large generated
    # block.
    replaced = @inline f(to_replace, gethead(args))
    return @inline unrollreplace(f, replaced, gettail(args))
end

"""
    unrollreplace_withcallback(f, to_replace, callback, args::Tuple)

Recursively apply `f` across `args`, then apply `callback` to the final
accumulator at the tuple terminator.
"""
@inline function unrollreplace_withcallback(f::F, to_replace::C, callback::CB, ::Tuple{}) where {F,C,CB}
    return @inline callback(to_replace)
end

@inline function unrollreplace_withcallback(f::F, to_replace::C, callback::CB, args::T) where {F,C,CB,T<:Tuple}
    # Recur through the same small-step path as `unrollreplace`, then apply the
    # callback at the terminator.
    replaced = @inline f(to_replace, gethead(args))
    return @inline unrollreplace_withcallback(f, replaced, callback, gettail(args))
end

"""
    unrollreplace_withargs(f, to_replace, as::Tuple; args = nothing, zip = nothing, zips = nothing)

Tuple-argument variant of `unrollreplace` with extra arguments passed to `f`.
For each item in `as`, the generated call order is:

```julia
f(acc, as[i])
f(acc, as[i], args...)
f(acc, as[i], args..., zip[i])
f(acc, as[i], args..., zips[1][i], zips[2][i], ...)
```

Use `zip` for one tuple or vector whose length matches `as`. Use `zips` for a
tuple of such tuple/vector zip inputs. `zip` and `zips` are mutually exclusive.
"""
@inline function unrollreplace_withargs(
    f::F,
    to_replace::C,
    as::T;
    args::AS = nothing,
    zip::Z = nothing,
    zips::ZS = nothing,
) where {F,C,T<:Tuple,AS,Z,ZS}
    if isnothing(zip) && isnothing(zips)
        return @inline _unrollreplace_withargs_recursive(f, to_replace, as, args)
    end
    return @inline _unrollreplace_withargs_generated(f, to_replace, as, args, zip, zips)
end

@inline _unrollreplace_withargs_recursive(f::F, to_replace::C, ::Tuple{}, args::A) where {F,C,A} = to_replace

"""Apply one recursive `unrollreplace_withargs` step with optional extra args."""
@inline function _unrollreplace_withargs_apply(f::F, to_replace::C, item, ::Nothing) where {F,C}
    return @inline f(to_replace, item)
end

@inline function _unrollreplace_withargs_apply(f::F, to_replace::C, item, args::A) where {F,C,A<:Tuple}
    return @inline f(to_replace, item, args...)
end

@inline function _unrollreplace_withargs_recursive(f::F, to_replace::C, as::T, args::A) where {F,C,T<:Tuple,A}
    replaced = @inline _unrollreplace_withargs_apply(f, to_replace, gethead(as), args)
    return @inline _unrollreplace_withargs_recursive(f, replaced, gettail(as), args)
end

@inline @generated function _unrollreplace_withargs_generated(f::F, to_replace::C, as::T, args::AS, zip::Z, zips::ZS) where {F,C,T<:Tuple, AS, Z, ZS}
    N = fieldcount(T)
    has_args = !(AS <: Nothing)
    has_zip = !(Z <: Nothing)
    has_zips = !(ZS <: Nothing)

    if has_zip && has_zips
        return :(throw(ArgumentError("unrollreplace_withargs accepts either `zip` or `zips`, not both.")))
    end
    if has_zip
        if Z <: Tuple
            fieldcount(Z) == N || return :(throw(ArgumentError("`zip` must have the same length as `as`.")))
        elseif !(Z <: AbstractVector)
            return :(throw(ArgumentError("`zip` must be a tuple or AbstractVector.")))
        end
    end
    if has_zips
        ZS <: Tuple || return :(throw(ArgumentError("`zips` must be a tuple of tuple/vector zip inputs.")))
        for j in 1:fieldcount(ZS)
            ZT = fieldtype(ZS, j)
            if ZT <: Tuple
                fieldcount(ZT) == N || return :(throw(ArgumentError("each tuple in `zips` must have the same length as `as`.")))
            elseif !(ZT <: AbstractVector)
                return :(throw(ArgumentError("`zips` must contain only tuples or AbstractVectors.")))
            end
        end
    end

    block = Expr(:block)
    # Tuple lengths are known from the type. Vector lengths are checked once
    # before emitting the fully unrolled calls below.
    if has_zip && Z <: AbstractVector
        push!(block.args, :(length(zip) == $N || throw(ArgumentError("`zip` must have the same length as `as`."))))
    end
    if has_zips
        for j in 1:fieldcount(ZS)
            ZT = fieldtype(ZS, j)
            if ZT <: AbstractVector
                push!(block.args, :(length(getfield(zips, $j)) == $N || throw(ArgumentError("each vector in `zips` must have the same length as `as`."))))
            end
        end
    end
    push!(block.args, :(r = to_replace))
    for i in 1:N
        call_args = Any[:r, :(getfield(as, $i))]
        has_args && push!(call_args, :(args...))
        if has_zip
            push!(call_args, Z <: Tuple ? :(getfield(zip, $i)) : :(zip[$i]))
        end
        if has_zips
            for j in 1:fieldcount(ZS)
                ZT = fieldtype(ZS, j)
                push!(call_args, ZT <: Tuple ? :(getfield(getfield(zips, $j), $i)) : :(getfield(zips, $j)[$i]))
            end
        end
        push!(block.args, :(r = $(Expr(:call, :f, call_args...))))
    end
    push!(block.args, :r)
    return block
end

# @inline @generated function unrollreplace_with_zippedargs(f::F, to_replace::C, as::T, args::AS) where {F,C,T<:Tuple, AS}
#     N = fieldcount(T)
#     block = Expr(:block, :(r = to_replace))
#     for i in 1:N
#         push!(block.args, :(r = f(r, gefield(args, $i)... , getfield(as, $i))))
#     end
#     push!(block.args, :r)
#     return block
# end


@inline @generated function unrollreplace_splat(f::F, to_replace::C, args::Vararg{Any,N}) where {F,C,N}
    block = Expr(:block, :(r = to_replace))
    for i in 1:N
        push!(block.args, :(r = f(r, getfield(args, $i))))
    end
    push!(block.args, :r)
    return block
end

"""
    unrollreplace_splat_withcallback(f, to_replace, callback, args...)

Splat-call wrapper for `unrollreplace_withcallback`.
"""
@inline function unrollreplace_splat_withcallback(f::F, to_replace::C, callback::CB, args::Vararg{Any,N}) where {F,C,CB,N}
    return @inline unrollreplace_withcallback(f, to_replace, callback, args)
end

@inline @generated function unrollreplace_splat_withargs(f::F, to_replace::C, as::Vararg{Any,N}; args) where {F,C,N}
    block = Expr(:block, :(r = to_replace))
    for i in 1:N
        push!(block.args, :(r = f(r, getfield(as, $i), args...)))
    end
    push!(block.args, :r)
    return block
end

"""
For a function that will return a viariable number of outputs
    that is broadcasted over a variable number of inputs,
    recursively splat the outputs in a tuple
"""
@inline function flat_collect_broadcast(f::F, elements::Tuple) where F
    if isempty(elements)
        return tuple()
    end
    result = (f(gethead(elements))...,)
    result = (result..., _flat_collect_broadcast(f, gettail(elements))...)
end

@inline function _flat_collect_broadcast(f::F, elements::Tuple) where F
    if isempty(elements)
        return tuple()
    end
    return (f(gethead(elements))..., _flat_collect_broadcast(f, gettail(elements))...)
end


"""
For a function that will return a viariable number of outputs
    that is broadcasted over a variable number of inputs,
    recursively splat the outputs in a tuple
"""
@inline function named_flat_collect_broadcast(f::F, elements::T) where {F, T <:Tuple}
    if isempty(elements)
        return (;)
    end
    result = (;f(gethead(elements))...,)
    result = (;result..., _named_flat_collect_broadcast(f, gettail(elements))...)
end

@inline function _named_flat_collect_broadcast(f::F, elements::T) where {F, T <:Tuple}
    if isempty(elements)
        return (;)
    end
    return (;f(gethead(elements))..., _named_flat_collect_broadcast(f, gettail(elements))...)
end

"""
Ntuple, but if f returns a tuple, flatten it
"""
Base.@constprop :aggressive @inline function flat_ntuple(f::F, n) where F
    function _flat_ntuple(f, v::Val{n}, ::Val{idx}) where {n, idx}
        if idx > n
            return tuple()
        else
            ret = f(idx)
            if ret isa Tuple
                return (ret..., _flat_ntuple(f, v, Val(idx + 1))...)
            else
                return (ret, _flat_ntuple(f, v, Val(idx + 1))...)
            end
        end
    end
    return @inline _flat_ntuple(f, Val(n), Val(1))
end

"""
For tree like structures, where an apply returns (nodes...), (traits...)
    We recur down the tree applying f(node, trait) at each level, and flattening in the end

    A stop condition is that f(node, traits) = nothing, nothing

    f needs to be function that takes (node, trait) and returns tuple(newnodes), tuple(newtraits)

    In the end we will end up with a flat tuple of nodes and a flat tuple of traits
"""
function flat_tree_property_recursion(nodefunc::F, elements::Tuple, traits::Tuple, mask = ntuple(_ -> true, length(elements))) where F
    function tuple_tuple_to_mask(t::Tuple, mask)
        flat_ntuple(i -> inner_tuple_to_mask(t[i], mask[i]), length(t))
    end

    function inner_tuple_to_mask(tup::Tuple, mask_el)
        t = ntuple(i -> mask_el * !isnothing(tup[1]), length(tup))
        return t
    end

    if all(mask .== false)
        return elements, traits
    end
    level_pairs = ntuple(length(elements)) do i
        if mask[i]
            thisel = elements[i]
            thistrait = traits[i]
            els, newtraits = nodefunc(thisel, thistrait)
            if !isnothing(els)
                if els isa Tuple
                    return (els...,), (newtraits...,)
                else
                    return (tuple(els), tuple(newtraits))
                end
            else
                return (tuple(nothing), tuple(nothing))
            end
        else
            return (tuple(elements[i]), tuple(traits[i]))
        end
    end

    justnodes = first.(level_pairs)
    justtraits = last.(level_pairs)

    curr_mask = map(x -> !isnothing(first(x)), justnodes)
    next_mask = tuple_tuple_to_mask(justnodes, mask)
    flat_replaced_nodes = flat_ntuple(length(curr_mask)) do i
        curr_mask[i]  ? justnodes[i]  : elements[i]
    end
    flat_replaced_traits = flat_ntuple(length(curr_mask)) do i
        curr_mask[i]  ? justtraits[i]  : traits[i]
    end
    return @inline flat_tree_property_recursion(nodefunc, flat_replaced_nodes, flat_replaced_traits, next_mask)
end


"""
Nodefunc should return either nothing or a tuple of new nodes
"""
function tree_flatten(nodefunc, node)
    applied = nodefunc(node)
    if isnothing(applied)
        return tuple(node)
    end

    return @inline flat_collect_broadcast(x -> tree_flatten(nodefunc, x), applied)
end
# TODO: EXPLAIN THE DIFFERENCE BETWEEN THE TWO TREE TRAIT FLATTENING FUNCS BELOW
"""
For a tree which has a branch level trait for each node
Nodefunction should return nothing, nothing
or next leaves, nodetrait 

This only works if every node has the same number of traits, and the traits are tuples
"""
@inline function tree_trait_flatten(nodefunc, node, carry_trait)
    next_nodes, newtrait = nodefunc(node, carry_trait)
    isnothing(next_nodes) && return (carry_trait,)
    return _ttf(nodefunc, next_nodes, newtrait)
end

@inline _ttf(nodefunc, ::Tuple{}, ::Tuple{}) = ()

@inline function _ttf(nodefunc, nodes::Tuple, traits::Tuple)
    (tree_trait_flatten(nodefunc, first(nodes), first(traits))...,
     _ttf(nodefunc, Base.tail(nodes), Base.tail(traits))...)
end

"""
Flatten a tree while collecting -node-local- traits.

`nodefunc(node)` must return `(next_nodes, trait)` where:
- `next_nodes === nothing` marks a leaf
- `next_nodes` is otherwise a tuple of child nodes to recurse into
- `trait` is the local trait payload for the current node

Traits are concatenated in traversal order. `nothing` traits are ignored, scalar
traits are wrapped as one-element tuples, and tuple traits are spliced in as-is.
"""
@inline _ttc_trait_tuple(::Nothing) = ()
@inline _ttc_trait_tuple(trait::Tuple) = trait
@inline _ttc_trait_tuple(trait) = (trait,)

@inline function tree_trait_flat_collect(nodefunc, node)
    next_nodes, trait = nodefunc(node)
    local_traits = _ttc_trait_tuple(trait)
    isnothing(next_nodes) && return local_traits
    next_nodes isa Tuple && isempty(next_nodes) && return local_traits
    return (local_traits..., flat_collect_broadcast(x -> tree_trait_flat_collect(nodefunc, x), next_nodes)...)
end

"""
Inlineable filter by type
"""
@inline function typefilter(type::Type{T}, elements) where T
    if isempty(elements)
        return tuple()
    end
    first_el = gethead(elements)
    if first_el isa T
        return (first_el, typefilter(T, gettail(elements))...)
    else
        return typefilter(T, gettail(elements))
    end
end

"""
Like `typefilter`, but if an element is a tuple it filters one level deeper inside that
tuple by type as well.

Top-level matches are kept as-is. Inner tuple matches are returned grouped in their
original outer slot. Empty inner results are dropped.
"""
@inline inner_typefilter(::Type{T}, elements) where {T} = _inner_typefilter(T, elements)

@inline _inner_typefilter(::Type{T}, ::Tuple{}) where {T} = ()

@inline function _inner_typefilter(::Type{T}, elements::Tuple) where {T}
    first_el = gethead(elements)
    tail_filtered = _inner_typefilter(T, gettail(elements))

    if first_el isa T
        return (first_el, tail_filtered...)
    elseif first_el isa Tuple
        inner_filtered = typefilter(T, first_el)
        if isempty(inner_filtered)
            return tail_filtered
        else
            return (inner_filtered, tail_filtered...)
        end
    else
        return tail_filtered
    end
end

@inline Base.keys(::Type{<:NamedTuple{Names}}) where {Names} = Names

Base.@constprop :aggressive @generated function _inner_typefilter(::Type{T}, elements::NT) where {T, NT<:NamedTuple}
    names = fieldnames(NT)
    field_exprs = Any[]

    for name in names
        FT = fieldtype(NT, name)
        value_expr = if FT <: T
            :(getproperty(elements, $(QuoteNode(name))))
        elseif FT <: Tuple
            inner_names = FT.parameters
            kept = [:(getfield(getproperty(elements, $(QuoteNode(name))), $i)) for (i, innerT) in enumerate(inner_names) if innerT <: T]
            isempty(kept) ? nothing : Expr(:tuple, kept...)
        else
            nothing
        end

        isnothing(value_expr) || push!(field_exprs, Expr(:kw, name, value_expr))
    end

    return Expr(:tuple, Expr(:parameters, field_exprs...))
end



"""
Apply a function f to the nodes of a tree, f returns (newchildren, tuple(whatever...))
    Not sure if this works
"""
function tree_apply_collect(f::F, node, collected = tuple()) where F
    newchildren, newcollect = f(node)

    if isnothing(newchildren)
        return (collected..., newcollect...)
    else

        next = flat_collect_broadcast(x -> tree_apply_collect(f, x), newchildren)
        return (collected..., newcollect..., next...)
    end
end
