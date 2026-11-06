#=
How a handle (`IdentifiableAlgo`) answers the hooks of `UniquePlanId` (Identifiable/UniquePlanId/Hooks.jl).
=#

# Its type-level id (parameter 2) is worked out from its matcher (`static_id`), so a handle is made again with
# `identifiable_with_id`; a handle without a matcher field keeps its id.
Base.@nospecializeinfer function rebuild_with_fields(@nospecialize(sa::IdentifiableAlgo), fields::Vector{Any})
    p = typeof(sa).parameters    # {F, Id, VarAliases, AlgoName, Key, M}
    matcher = fields[2]
    return identifiable_with_id(fields[1], isnothing(matcher) ? p[2] : matcher, p[3], p[4], p[5])
end
