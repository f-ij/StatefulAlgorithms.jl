using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using StatefulAlgorithms
import StatefulAlgorithms as ps

@ProcessAlgorithm function Predict(state, velocity, dt)
    state = state + velocity * dt
    return (;state)
end

@ProcessAlgorithm function Observe(state, noise)
    measurement = state + noise
    return (;measurement)
end

@ProcessAlgorithm function Update(state, measurement, gain)
    state = state + gain * (measurement - state)
    return (;state)
end

function StatefulAlgorithms.init(::Predict, input)
    return (;state = 0.0, velocity = 1.0, dt = 0.1)
end

function StatefulAlgorithms.init(::Observe, input)
    return (;noise = 0.05)
end

function StatefulAlgorithms.init(::Update, input)
    return (;gain = 0.2)
end

Tracker = Routine((Predict, Observe, Update), (3, 1, 1),
    Route(Predict, Observe, :state => :state),
    Route(Observe, Update, :measurement => :measurement))

p = Process(Tracker, lifetime = 15)
start(p)
