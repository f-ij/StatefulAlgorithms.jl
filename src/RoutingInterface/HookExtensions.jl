#=
How the wiring (`Route`, `Share`, `Redirect`) answers the hooks of the matching system (Matching.jl).
=#

# Fields 1 and 2 are the endpoints (handles, kept until the plan is resolved); type parameters 1 and 2 are their
# matchers (`scref_match`), worked out again from the new endpoints, and the parameters the endpoint fields are declared
# as follow their new types. An endpoint that is `nothing` keeps its matcher.
function map_matchers_of_type(M::Type, @nospecialize(w::Union{Route, Share, Redirect}), f)
    ends = (getfield(w, 1), getfield(w, 2))
    new = (map_matchers_of_type(M, ends[1], f), map_matchers_of_type(M, ends[2], f))
    new[1] === ends[1] && new[2] === ends[2] && return w
    T = typeof(w)
    params = Any[T.parameters...]
    for i in 1:2
        j = _field_parameter_index(T, i)
        isnothing(j) || (params[j] = typeof(new[i]))
        isnothing(new[i]) || (params[i] = scref_match(new[i]))
    end
    return new_instance(Core.apply_type(T.name.wrapper, params...), new...)
end
