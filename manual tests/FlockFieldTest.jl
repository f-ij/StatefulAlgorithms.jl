using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using StatefulAlgorithms
import StatefulAlgorithms as ps

@ProcessAlgorithm function AgentsStep(positions, velocity)
    positions = positions .+ velocity
    return (;positions)
end

@ProcessAlgorithm function FieldDiffuse(field, diffusion)
    field = field .* (1.0 - diffusion)
    return (;field)
end

@ProcessAlgorithm function FieldSense(positions, field, strength)
    if !isempty(positions)
        positions = positions .+ strength * field
    end
    return (;positions)
end

function StatefulAlgorithms.init(::AgentsStep, input)
    return (;positions = [0.0, 1.0], velocity = 0.1)
end

function StatefulAlgorithms.init(::FieldDiffuse, input)
    return (;field = 0.5, diffusion = 0.05)
end

function StatefulAlgorithms.init(::FieldSense, input)
    return (;strength = 0.02)
end

FlockField = CompositeAlgorithm((AgentsStep, FieldDiffuse, FieldSense), (1, 1, 1),
    Share(AgentsStep, FieldSense))

p = Process(FlockField, lifetime = 25)
start(p)
