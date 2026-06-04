include("_env.jl")
import StatefulAlgorithms as ps

@ProcessAlgorithm function Oscillator(state, velocity, dt, trajectory)
    new_vel = velocity - state * dt
    new_state = state + new_vel * dt
    push!(trajectory, new_state)
    return (;state = new_state, velocity = new_vel)
end

function StatefulAlgorithms.init(::Oscillator, context)
    (;dt) = context
    trajectory = Float64[1.0]
    processsizehint!(trajectory, context)
    return (;state = 1.0, velocity = 0.0, dt, trajectory)
end

@ProcessAlgorithm function DampedFollower(state, velocity, damp, trajectory)
    velocity = velocity * (1.0 - damp)
    push!(trajectory, state)
    return (;velocity)
end

function StatefulAlgorithms.init(::DampedFollower, context)
    return (;damp = 0.05)
end

# Share the entire subcontext between Oscillator and DampedFollower
SharedOsc = CompositeAlgorithm((Oscillator, DampedFollower), (1, 1),
    Share(Oscillator, DampedFollower))

p = Process(SharedOsc, lifetime = 20, Input(Oscillator, :dt => 0.1))
start(p)
