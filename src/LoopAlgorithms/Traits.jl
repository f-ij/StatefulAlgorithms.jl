@generated function algo_and_interval_iterator(cla)
    numalgos = StatefulAlgorithms.numalgos(cla)
    exprs = (Expr(:tuple, :(getindex(getalgos(cla), $i)), :(interval(cla, $i))) for i in 1:numalgos)
    return Expr(:tuple, exprs...)
end

const LoopAlgorithmTypes = Union{LoopSpec, Type{<:LoopSpec}}

#=
Traits of plan types: what a plan is, decided by its type. A plan type answers them with its own method; a wrapper of a
loop algorithm asks what it wraps (`FinalizedAlgorithm/FinalizedAlgorithm.jl`). `ThreadedCompositeAlgorithm`'s are in
Threaded/CompositeAlgorithms.jl.
=#

"""
    iscomposite(x) -> Bool

Whether `x` (a value or a type) is a composite plan, which steps all its children in order each step: `false` by
default.
"""
@inline iscomposite(x::T) where {T} = false
@inline iscomposite(::Type{LS}) where {LS<:LoopSpec} = false
@inline iscomposite(::Type{CA}) where {CA<:CompositeAlgorithm} = true
@inline iscomposite(::Type{LA}) where {Plan, LA<:LoopAlgorithm{Plan}} = iscomposite(Plan)
@inline iscomposite(la::LA) where {LA<:LoopSpec} = iscomposite(typeof(la))

"""
    steps_inline(ChildType) -> Bool

Whether a child of type `ChildType` has its step written into its parent's step (Step.jl, the file header, 1.):
`true` for a plan with a step writer (`_plan_step_exprs`: `CompositeAlgorithm`, `Routine`), `false` for anything else,
which is stepped by a call to its `_step!`. A plan type that answers `true` must add a `_plan_step_exprs` method.
"""
@inline steps_inline(::Type{T}) where {T} = false
@inline steps_inline(::Type{P}) where {P<:Union{CompositeAlgorithm, Routine}} = true
