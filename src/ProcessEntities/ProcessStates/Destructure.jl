export Destructure, DynamicStore, destructure, release!, getdestructure_id, getdynamicstore_id
export DestructureInput

abstract type AbstractDestructure{T,F} <: ProcessState end

"""
ProcessState wrapper for an arbitrary value that is destructured into its fields
during init.
"""
struct Destructure{T,F} <: AbstractDestructure{T,F}
    obj::T
    func::F
end

hasfunc(d::Union{Destructure{T,F}, Type{<:Destructure{T,F}}}) where {T,F} = !(F <: Nothing)

function Destructure(x::T, func::F = nothing) where {T, F<:Union{Nothing, Function}}
    wrapped = isbitstype(T) ? x : DynamicStore(x)
    return Destructure{typeof(wrapped), F}(wrapped, func)
end

"""
For do syntax
"""
Destructure(f::Function, x::T) where {T} = Destructure(x, f)

function getdestructure_id(x)
    return getdynamicstore_id(x)
end

function getvalue(d::Destructure)
    if d.obj isa DynamicStore
        return getvalue(d.obj)
    else
        return d.obj
    end 
end

destructure(x::NamedTuple) = x

@generated function destructure(x::T) where {T}
    names = fieldnames(T)
    if isempty(names)
        return :(NamedTuple{()}(()))
    end
    vals = [:(getfield(x, $(QuoteNode(n)))) for n in names]
    return :(NamedTuple{$(names)}(($(vals...),)))
end

function init(d::Destructure, context::AbstractContext)
    value = getvalue(d)
    valuename = Symbol(lowercase(string(nameof(typeof(value)))))
    fields = destructure(value)
    fields = (;valuename => value, fields...)
    if hasfunc(d)
        fields = d.func(fields, context)
    end
    return fields
end

## CONTAINER
thincontainer(::Type{<:Destructure}) = true
function (d::Destructure{T,F})(newobj::O) where {T,F,O<:T} # Composition rule
    return Destructure(newobj, d.func)
end
_contained_type(::Type{<:Destructure{T, F}}) where {T, F} = contained_type(T)
_unwrap_container(d::Destructure{T, F}) where {T, F} = getvalue(d)
# _unwrap_container(d::Destructure{T, F}) where {T, F} = d.obj


################################
####### Destruct an input ######
################################
struct DestructureInput{F} <: ProcessState
    func::F

    function DestructureInput(f::Union{Function, Nothing} = nothing)
        return new{typeof(f)}(f)
    end
end

hasfunc(d::Union{DestructureInput{F}, Type{<:DestructureInput{F}}}) where {F} = !(F <: Nothing)

function init(d::DestructureInput, context::AbstractContext)
    (;structure) = context
    valuename = Symbol(lowercase(string(nameof(typeof(structure)))))
    fields = destructure(structure)
    fields = (;valuename => structure, fields...)
    if hasfunc(d)
        fields = d.func(fields, context)
    end
    return fields
end
