using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using StatefulAlgorithms, Random
import StatefulAlgorithms as ps

struct Walker <: ProcessAlgorithm end

function StatefulAlgorithms.step!(::Walker, context::C) where C
    (;state, momentum, dt) = context
    println("State is now $state")
    println("pushing : $(momentum) * dt)")
    push!(state, state[end] + momentum * dt)
    return (;momentum)
end

function StatefulAlgorithms.init(::Walker, input::A) where A
    (;dt) = input

    state = Float64[1.0]
    momentum = 1.0
    println("dt: $dt")
    processsizehint!(state, input)
    return (;state, momentum, dt)
end

@ProcessAlgorithm @config seed::Int = 1234 function InsertNoise(targetnum, scale, @managed(rng = MersenneTwister(seed)))
    T = typeof(targetnum)
    println("Seed is: $(seed)")
    rand_num = (rand(rng, T) - T(0.5)) * T(2) * scale
    println("Adding noise: $rand_num")
    println("Scale: $scale")
    targetnum = targetnum + rand_num
    return (; targetnum)
end

# RandomWalker = CompositeAlgorithm(Walker, InsertNoise(), (1, 2), Route(Walker => InsertNoise(), :momentum => :targetnum, :dt => :scale))
RandomWalker = @CompositeAlgorithm begin
    momentum, dt,  = Walker()
    InsertNoise(130)(scale = dt, targetnum = momentum)
end

p = Process(RandomWalker, lifetime = 10, Input(Walker, :dt => 0.01))
run(p)

