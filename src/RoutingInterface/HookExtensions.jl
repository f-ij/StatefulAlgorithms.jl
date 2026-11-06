#=
How the wiring (`Route`, `Share`, `Redirect`) answers the hooks of `UniquePlanId` (Identifiable/UniquePlanId/Hooks.jl).
=#

# Fields 1 and 2 are the endpoints; type parameters 1 and 2 are their matchers (`scref_match`), worked out again from
# the new endpoints. An endpoint that is `nothing` keeps its matcher. The other parameters as `rebuild_with_fields`'s
# default sets them.
Base.@nospecializeinfer function rebuild_with_fields(@nospecialize(w::Union{Route, Share, Redirect}), fields::Vector{Any})
    T = typeof(w)
    params = _params_from_fields(T, fields)
    for i in 1:2
        isnothing(fields[i]) || (params[i] = scref_match(fields[i]))
    end
    return new_instance(Core.apply_type(T.name.wrapper, params...), fields...)
end
