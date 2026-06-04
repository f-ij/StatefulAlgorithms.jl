

# export PrepereHelper, add_algorithm!, unique_algorithms

# """
# For routines and composite algorithms, this tracks every unique function used within.
# Moreover, it tracks how many number of times each algorithm will be called
# Lastly, it will track within the init functions which one of the unique functions is being prepared

# This allows for function agnistic tools like processsizehint! that gives a sizehint to a vector
#     in the init function without having to redefine the init function it around when a user changes the total lifetime of a process
#     or occurrences of the function within composite algorithms/routines
# """
# mutable struct PrepereHelper{PA, T, TC, TR, LT}
#     const pa::PA
#     const unique_algos::T
#     const counts::TC
#     const multipliers::TR
#     const lifetime::LT
#     current::Int
# end

# """
# Walks the algorithm tree and builds a PrepereHelper for all unique algorithms within
#     Repeats are calculated based on the number of times each algorithm is called within the composite algorithm/routine
#     This has to be multiplied with the lifetime of the parent process to get the total repeats for the process
# """
# function PrepereHelper(pa::ProcessLoopAlgorithm, args)
#     (;lifetime) = args
#     unique_algos = UniqueFlatten(pa)
#     counts = typecounts(pa)
#     u_multipliers = unique_multipliers(pa)
#     PrepereHelper(pa, unique_algos, counts, u_multipliers, lifetime, 1)
# end

# function PrepereHelper(pa::CompositeAlgorithm, args)
#     (;lifetime) = args
#     ph = PrepereHelper(pa, (pa,), (1,), (1,), lifetime, 1)
# end

# # function add_algorithm!(algo, repeats, counts_dict, repeats_dict)
# #     if !haskey(ph.counts, algo)
# #         ph.counts[algo] = 1
# #         ph.repeats[algo] = repeats
# #     else
# #         ph.counts[algo] += 1
# #         ph.repeats[algo] += repeats
# #     end
# # end

# Base.getindex(ph::PrepereHelper, idx) = collect(keys(ph.counts))[idx]

# unique_algorithms(ph::PrepereHelper) = keys(ph.counts)
# total_repeats(ph::PrepereHelper) = ph.repeats
# getalgo(ph::PrepereHelper, idx) = getindex(ph.unique_algos, idx)
# this_algo(args) = getalgo(args.ph, args.ph.current)
# getalgo(ph::PrepereHelper) = ph.pa
# lifetime(ph::PrepereHelper) = ph.lifetime
# repeats(ph::PrepereHelper) = repeats(ph.lifetime)

# function Base.iterate(ph::PrepereHelper, state = 0)
#     next_idx = state + 1
#     next_idx > length(ph.counts) && return nothing
#     ph.current = next_idx
#     return getalgo(ph, next_idx), next_idx
# end

# function next!(ph::PrepereHelper)
#     ph.current += 1
# end

# currentalgo(ph::PrepereHelper) = getalgo(ph, ph.current)
# current_repeats(ph::PrepereHelper) = ph.repeats[currentalgo(ph)]
# current_counts(ph::PrepereHelper) = ph.counts[currentalgo(ph)]

# function init(ph::PrepereHelper, args)
#     returnargs = (;)
#     # for a in unique_algorithms(ph)
#     for a in ph
#         newargs = init(a, (;args..., ph))            # Add algo tracker to args
#         # overlap = intersect(keys(returnargs), keys(newargs))  # Find wether there are overlapping keys between the algorithms
#         @static if DEBUG_MODE
#             println("Preparing arguments using the PrepereHelper for algorithm $a")
#             println("Keys of args are: $(keys(args))")
#             println("Keys of new args are: $(keys(newargs))")
#         end
#         # if !isempty(overlap)
#         #     @warn "Multiple algorithms define the same arguments: $overlap. \n Only one of them will be used with a random order."
#         # end
#         # returnargs = (;returnargs..., newargs...)                  # Add the new arguments to the existing ones
#         name = nothing
#         if a isa Type
#             name = nameof(a)
#         else
#             name = nameof(typeof(a))
#         end
#         returnargs = (;returnargs..., name => newargs)                  # Add the new arguments to the existing ones
#     end
#     returnargs = (;args..., returnargs...) # Inputargs are at top_level

#     return deletekeys(returnargs, :ph)
# end

# function cleanup(ph::PrepereHelper, args)
#     # for a in unique_algorithms(ph)
#     for a in ph
#         name = nameof(typeof(a))

#         # Splat the algorithms args
#         newargs = cleanup(a, (;getproperty(ph, name)..., ph))
#         args = (;args..., name => newargs)
#         # next!(ph)
#     end
#     returnargs = deletekeys(args, :ph)
#     return returnargs
# end

