export Local

"""
    Local(; name = initial_value, ...)

Declare loop-local variables on a plan, like `local x = 0` before a Julia `for` loop.

Pass it to `CompositeAlgorithm(...)` or `Routine(...)` like a route. The variables
are created when a run starts, every child can read them by name, and a child
updates one by returning that name. The initial value fixes the type: returned
values are converted to it, so the carried context never changes shape. They are
visible to `finalstep` and kept across pause/resume, but not stored after the run.

Sharing a value between children or across steps means declaring it here;
undeclared step returns are not meant to outlive the step that produced them.

Currently all declarations in a plan tree are run-level (created once per run),
including ones on nested plans.
"""
struct Local{NT<:NamedTuple} <: AbstractOption
    values::NT
end

Local(; values...) = Local(NamedTuple(values))

"""Return the declared initial values carried by a `Local`."""
@inline getvalues(l::Local) = getfield(l, :values)

"""All `Local` declarations among `options`, merged into one named tuple of initial values."""
@inline declared_locals(options::Tuple{}) = (;)
@inline declared_locals(options::Tuple) = merge(_local_values(first(options)), declared_locals(Base.tail(options)))
@inline _local_values(l::Local) = getvalues(l)
@inline _local_values(::Any) = (;)

"""Initial values of the locals declared on a loop algorithm's plan tree."""
@inline declared_locals(la::LoopAlgorithm) = declared_locals(getoptions(la))
@inline declared_locals(fa::FinalizedAlgorithm) = declared_locals(inneralgorithm(fa))
@inline declared_locals(::Any) = (;)

"""
Write returned values into the declared locals, keeping every field's declared type
(like a typed Julia local): values are converted, and a `Union{Nothing,T}` field stays a union.
"""
@inline @generated function _merge_declared(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    values = map(fieldnames(NT)) do name
        name in fieldnames(A) ? :(convert($(fieldtype(NT, name)), getfield(args, $(QuoteNode(name))))) :
                                :(getfield(old, $(QuoteNode(name))))
    end
    return :($NT(($(values...),)))
end
