export Var
struct Var{Entity, name} end

Var(entity, name) = Var{entity, name}()
Var(name) = Var{:globals, name}()

"""
    c[Var(entity, name)]

Return the value of field `name` of `entity`. A field replaced by `Replace`
returns the value of the field it points to, not its `ReplacedVar` marker.
"""
@inline function Base.getindex(c::ProcessContext, var::Var{Entity, name}) where {Entity, name}
    @inline context_value(c, getproperty(c[Entity], name))
end

"""
    context_value(c, stored)

Return the value a stored field reads as: `stored` itself, or for a
`ReplacedVar` marker the value at the location it points to in `c`.
"""
@inline context_value(c::ProcessContext, stored) = stored
@inline function context_value(c::ProcessContext, ::ReplacedVar{VL}) where {VL}
    @inline c[Var(get_subcontextname(VL), get_originalname(VL))]
end

@inline function Base.getindex(c::ProcessContext, vars::Var...)
    ntuple(Val(length(vars))) do i
        @inline getindex(c, vars[i])
    end
end

@inline function Base.getindex(c::SubContext, vars::Var...)
    ntuple(Val(length(vars))) do i
        getindex(c, vars[i])
    end
end

@inline function Base.getindex(c::ProcessContext, var::Var{:globals, name}) where {name}
    getglobals(c)[name]
end

"""
Read a DSL runtime variable selector from `ProcessContext._runtime`.
"""
@inline function Base.getindex(c::ProcessContext, var::Var{:_runtime, name}) where {name}
    getglobals(c)[name]
end
