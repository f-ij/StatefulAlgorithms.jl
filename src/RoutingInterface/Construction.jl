################################################
############ WIRING CONSTRUCTION ##############
################################################

"""Build the expression that reconstructs a resolved wiring tree from type data."""
function _wiring_value_expr(::Type{T}) where {T}
    if T === Nothing
        return :(nothing)
    elseif T <: Tuple
        return Expr(:tuple, (_wiring_value_expr(fieldtype(T, i)) for i in 1:fieldcount(T))...)
    elseif T <: NamedTuple
        values = Expr(:tuple, (_wiring_value_expr(fieldtype(T, i)) for i in 1:fieldcount(T))...)
        return :($T($values))
    else
        return :($T())
    end
end

"""
Instantiate a wiring value from its type.

Resolved wiring is pure type data: routes and shares have no endpoint fields,
`Wiring` only contains route/share tuples, and `PlanWiring` only contains
target-grouped/global wiring plus child-indexed wiring. This helper rebuilds
those values from type information so hot stepping code does not have to carry
or inspect runtime wiring fields.
"""
@inline @generated function wiring_from_type(::Type{T}) where {T}
    return _wiring_value_expr(T)
end

"""Construct resolved route/share wiring from type data."""
@inline @generated function Wiring{Routes, Shares}() where {Routes<:Tuple, Shares<:Tuple}
    wiring_type = Wiring{Routes, Shares}
    return :($wiring_type(
        $(_wiring_value_expr(Routes)),
        $(_wiring_value_expr(Shares)),
    ))
end

"""Construct resolved plan wiring from type data."""
@inline @generated function PlanWiring{GlobalWiring, ChildWiring}() where {GlobalWiring, ChildWiring<:Tuple}
    plan_wiring_type = PlanWiring{GlobalWiring, ChildWiring}
    return :($plan_wiring_type(
        $(_wiring_value_expr(GlobalWiring)),
        $(_wiring_value_expr(ChildWiring)),
    ))
end
