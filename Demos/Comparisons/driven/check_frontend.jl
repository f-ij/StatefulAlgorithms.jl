using LinearAlgebra
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl")); include(joinpath(@__DIR__, "modifiers.jl"))
include(joinpath(@__DIR__, "frontend.jl"))
h = hand_setup(sine_force); hand_mod_loop!(h, Val(true), Val(true), Val(true))
la, integ = package_experiment(); c = StatefulAlgorithms.getstoredcontext(la)
si, snaps = sciml_experiment()
println("package: attempts ", (c[integ].nacc, c[integ].nrej), " identical to hand-written: ", c[integ].u == h.u)
println("SciML:   attempts ", (si.stats.naccept, si.stats.nreject), " checkpoints ", length(snaps), " rel. diff to hand-written: ", norm(si.u .- h.u) / norm(h.u))
