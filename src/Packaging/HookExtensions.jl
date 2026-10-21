#=
How a `Package` extends the hooks of loop algorithms (LoopAlgorithms/Hooks.jl): a reset restarts its interval counter
and resets its algorithms.
=#

"""Reset a package before it runs again: restarts its interval counter and resets each of its algorithms."""
@inline reset!(pkg::Package) = (getinc(pkg)[] = 1; reset!.(getalgos(pkg)); pkg)
