using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using StatefulAlgorithms
import StatefulAlgorithms as ps

@ProcessAlgorithm function PreyGrowth(prey, rate)
    prey = prey + prey * rate
    return (;prey)
end

@ProcessAlgorithm function Predation(prey, predators, attack)
    eaten = attack * prey * predators
    prey = max(prey - eaten, 0.0)
    predators = predators + eaten * 0.01
    return (;prey, predators)
end

@ProcessAlgorithm function ControlPulse(prey, inject)
    prey = prey + inject
    return (;prey)
end

function StatefulAlgorithms.init(::PreyGrowth, input)
    return (;prey = 50.0, rate = 0.02)
end

function StatefulAlgorithms.init(::Predation, input)
    return (;predators = 5.0, attack = 0.001)
end

function StatefulAlgorithms.init(::ControlPulse, input)
    return (;inject = 10.0)
end

PopDynamics = CompositeAlgorithm((PreyGrowth, Predation, ControlPulse), (1, 1, 10),
    Route(PreyGrowth, Predation, :prey => :prey),
    Route(Predation, ControlPulse, :prey => :prey))

p = Process(PopDynamics, lifetime = 50)
start(p)
