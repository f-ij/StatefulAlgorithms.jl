#=
How a handle (`IdentifiableAlgo`) answers the hooks of the matching system (Matching.jl).
=#

# Its `func` first (a nested plan's handles), then its own matcher: a new matcher makes the handle again through
# `setmatcher`, which works its type-level id (parameter 2) out from it. A handle whose matcher is in its type alone
# (`id` gives that type) has no matcher value to replace.
function map_matchers_of_type(M::Type, @nospecialize(sa::IdentifiableAlgo), f)
    sa = map_matchers_in_fields(M, sa, f, (:func,))
    matcher = id(sa)
    new = map_matchers_of_type(M, matcher, f)
    return new === matcher ? sa : setmatcher(sa, new)
end
