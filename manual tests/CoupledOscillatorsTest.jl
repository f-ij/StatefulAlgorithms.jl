using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using StatefulAlgorithms
import StatefulAlgorithms as ps

@ProcessAlgorithm function OscillatorA(phase, freq, dt)
    phase = phase + freq * dt
    return (;phase)
end

@ProcessAlgorithm function OscillatorB(phase, freq, dt)
    phase = phase + freq * dt
    return (;phase)
end

@ProcessAlgorithm function Coupling(phase_a, phase_b, strength)
    phase_a = phase_a + strength * (phase_b - phase_a)
    phase_b = phase_b + strength * (phase_a - phase_b)
    return (;phase_a, phase_b)
end

function StatefulAlgorithms.init(::OscillatorA, input)
    return (;phase = 0.0, freq = 1.0, dt = 0.05)
end

function StatefulAlgorithms.init(::OscillatorB, input)
    return (;phase = 1.0, freq = 0.9, dt = 0.05)
end

function StatefulAlgorithms.init(::Coupling, input)
    return (;strength = 0.1)
end

Coupled = CompositeAlgorithm((OscillatorA, OscillatorB, Coupling), (1, 1, 1),
    Route(OscillatorA, Coupling, :phase => :phase_a),
    Route(OscillatorB, Coupling, :phase => :phase_b))

p = Process(Coupled, lifetime = 40)
start(p)
fetch(p)

# c = p.context
# reg = getregistry(c)
# coup = reg[3][1]
# scv = view(c, coup)