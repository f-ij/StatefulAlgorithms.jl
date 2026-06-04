# """
# If a fused LoopAlgorithm is given, get the subcontext for the first of its contained algorithms
#     Since all the id's match and after fusing, and are unique, matching the first algorithm
#         Must be the same for all contained algorithms
# """
# function Base.getindex(context::ProcessContext, la::LoopAlgorithm)
#     if !isfused(la)
#         error("Cannot get subcontext for non-fused LoopAlgorithm")
#     end

#     first_algo = getalgo(la, 1)
#     return getindex(context, first_algo)
# end
