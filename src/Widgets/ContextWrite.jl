export ContextWrite

"""
Small process algorithm that writes a captured value to one context variable.

When the destination already exists in the current view, the captured value is
converted to the destination's current runtime type before it is returned.
"""
struct ContextWrite{Loc, T} <: ProcessAlgorithm
    fieldlocation::Loc
    val::T
end

ContextWrite(fieldlocation::Symbol, val) = ContextWrite(Val(fieldlocation), val)
ContextWrite(fieldlocation::Symbol) = ContextWrite(Val(fieldlocation), nothing)

@inline _contextwrite_raw_value(val, context) = val
@inline _contextwrite_raw_value(::Nothing, context) = getproperty(context, :value)

@inline function _contextwrite_value(::Val{name}, val, context) where {name}
    raw = _contextwrite_raw_value(val, context)
    if haskey(context, name)
        current = getproperty(context, name)
        return convert(typeof(current), raw)
    end
    return raw
end

@inline function step!(cw::ContextWrite{Val{name}}, context) where {name}
    value = _contextwrite_value(Val(name), getfield(cw, :val), context)
    return NamedTuple{(name,)}((value,))
end

function Base.show(io::IO, cw::ContextWrite{Val{name}}) where {name}
    print(io, "ContextWrite(", name, " = ", repr(getfield(cw, :val)), ")")
end

@inline function context_broadcast!(target, value)
    broadcast!(identity, target, value)
    return nothing
end

@inline function context_broadcast_index!(target, value, indices...)
    broadcast!(identity, view(target, indices...), value)
    return nothing
end
