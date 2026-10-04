export Local

"""
    Local(; name = initial_value, ...)

Declare loop-local variables on a plan, like `local x = 0` before a Julia `for` loop.

Pass it to `CompositeAlgorithm(...)` or `Routine(...)` like a route. The variables
are created when a run starts, every child can read them by name, and a child
updates one by returning that name. The initial value fixes the type: returned
values are converted to it, so the carried context never changes shape. With
`name = undef` the first value written fixes the type instead. They are
visible to `finalstep` and kept across pause/resume, but not stored after the run.

Sharing a value between children or across steps means declaring it here;
undeclared step returns are not meant to outlive the step that produced them.

Currently all declarations in a plan tree are run-level (created once per run),
including ones on nested plans.
"""
struct Local{NT<:NamedTuple} <: AbstractOption
    values::NT
    Local{NT}(values::NT) where {NT<:NamedTuple} = new{NT}(values)
end

Local(; values...) = Local(NamedTuple(values))

# A field declared `Union{Nothing,T}` is stored as `Maybe{T}`: a flag plus a value. A Julia
# Union field in the carried context blocks keeping it in registers (stack copies every step);
# `Maybe` keeps it registerizable, and reads turn it back into `nothing` or the value.
Local(values::NT) where {NT<:NamedTuple} = Local{_local_storage_type(NT)}(_local_storage(values))

"""Flag-plus-value storage for a local declared `Union{Nothing,T}`; `value` is undefined while unset."""
struct Maybe{T, F<:Unsigned}
    isset::F      # as wide as T's alignment: a 1-byte Bool would leave padding that gets copied every step
    value::T
    Maybe{T}() where {T} = new{T, _maybe_flagtype(T)}(zero(_maybe_flagtype(T)))
    Maybe{T}(x) where {T} = new{T, _maybe_flagtype(T)}(one(_maybe_flagtype(T)), x)
end
_maybe_flagtype(::Type{T}) where {T} = (a = Base.datatype_alignment(T); a >= 8 ? UInt64 : a == 4 ? UInt32 : a == 2 ? UInt16 : UInt8)
Base.convert(::Type{<:Maybe{T}}, ::Nothing) where {T} = Maybe{T}()
Base.convert(::Type{<:Maybe{T}}, x) where {T} = Maybe{T}(convert(T, x))
Base.convert(::Type{M}, m::M) where {M<:Maybe} = m
# `Local(x = undef)` declares a local without a value, like `local x` in Julia but without
# making `x` a `Union`. The first value written fixes the type; later writes are converted
# to it. Reads always see that type; reading before the first write throws `UndefRefError`.
_throw_undef() = throw(UndefRefError())
@inline subcontext_view_value(::UndefInitializer, view::V) where {V<:SubContextView} = _throw_undef()

# `Local(x = nothing)` works like `x = nothing` before a Julia loop: reads see `nothing`
# until the first other value is written, and from then on `x` is a `Union{Nothing,T}`
# (stored as `Maybe{T}`), so writing `nothing` again is allowed.
@inline _first_write_after_nothing(::Nothing) = nothing
@inline _first_write_after_nothing(x::T) where {T} = Maybe{T}(x)

"""Reads of a `Maybe` local see `nothing` or the stored value."""
@inline subcontext_view_value(m::Maybe, view::V) where {V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? subcontext_view_value(getfield(m, :value), view) : nothing

_storage_fieldtype(::Type{T}) where {T} = (T isa Union && Nothing <: T && T !== Nothing) ? Maybe{Base.typesplit(T, Nothing), _maybe_flagtype(Base.typesplit(T, Nothing))} : T
@generated _local_storage_type(::Type{NT}) where {NT<:NamedTuple} =
    :(NamedTuple{$(fieldnames(NT)), Tuple{$(map(_storage_fieldtype, fieldtypes(NT))...)}})
@inline _local_storage(values::NT) where {NT<:NamedTuple} =
    _local_storage_type(NT)(map((T, v) -> convert(T, v), fieldtypes(_local_storage_type(NT)), Tuple(values)))

"""Return the declared initial values carried by a `Local`."""
@inline getvalues(l::Local) = getfield(l, :values)

"""All `Local` declarations among `options`, merged into one named tuple of initial values."""
@inline declared_locals(options::Tuple{}) = (;)
@inline declared_locals(options::Tuple) = merge(_local_values(first(options)), declared_locals(Base.tail(options)))
@inline _local_values(l::Local) = getvalues(l)
@inline _local_values(::Any) = (;)

"""`options` plus a `Local` that rebuilds the plan wiring's declarations (for plan edits)."""
_with_local_options(options::Tuple, wiring::PlanWiring) =
    isempty(getfield(wiring, :locals)) ? options : (options..., Local{typeof(getfield(wiring, :locals))}(getfield(wiring, :locals)))

"""
Name of a local's slot in the runtime `_local` subcontext. A local declared on the root
plan keeps its name; one declared on a nested plan is suffixed with that plan's position.
"""
local_storage_name(name::Symbol, path::Tuple{}) = name
local_storage_name(name::Symbol, path::Tuple) = Symbol(name, "@", join(path, "."))

"""
Initial values of every local declared in a plan tree, keyed by storage name: the
memory for all of them is allocated in `_local` when a run starts.
"""
@generated function _tree_locals(plan::P) where {P<:AbstractPlan}
    names = Symbol[]
    values = Any[]
    function collect!(::Type{T}, expr, path) where {T}
        for name in fieldnames(fieldtype(fieldtype(T, :wiring), :locals))
            push!(names, local_storage_name(name, path))
            push!(values, :(getfield(getfield(getfield($expr, :wiring), :locals), $(QuoteNode(name)))))
        end
        F = fieldtype(T, :funcs)
        for i in 1:fieldcount(F)
            fieldtype(F, i) <: AbstractPlan && collect!(fieldtype(F, i), :(getfield(getfield($expr, :funcs), $i)), (path..., i))
        end
    end
    collect!(P, :plan, ())
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end

"""Initial values of the locals declared on a loop algorithm's plan tree."""
@inline declared_locals(la::LoopAlgorithm) = _tree_locals(getplan(la))
@inline declared_locals(fa::FinalizedAlgorithm) = declared_locals(inneralgorithm(fa))
@inline declared_locals(::Any) = (;)

"""
Write returned values into the declared locals, keeping every field's declared type
(like a typed Julia local): values are converted, and a `Union{Nothing,T}` field stays a union.
"""
@inline @generated function _merge_declared(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    values = map(fieldnames(NT)) do name
        !(name in fieldnames(A)) ? :(getfield(old, $(QuoteNode(name)))) :
        fieldtype(NT, name) === UndefInitializer ? :(getfield(args, $(QuoteNode(name)))) :   # first write fixes the type
        fieldtype(NT, name) === Nothing ? :(@inline _first_write_after_nothing(getfield(args, $(QuoteNode(name))))) :
                                              :(convert($(fieldtype(NT, name)), getfield(args, $(QuoteNode(name)))))
    end
    return :(NamedTuple{$(fieldnames(NT))}(($(values...),)))
end
