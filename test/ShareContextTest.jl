using Test
using StatefulAlgorithms

@testset "Share: shared variables propagate across subcontexts" begin
    # This mirrors `manual tests/ShareTest.jl` and verifies that `Share(...)` makes
    # variables from one subcontext available (and writable) to the other.

    @ProcessAlgorithm function Oscillator(@managed(dt), @managed(state = 1.0), @managed(velocity = 0.0), @managed(trajectory = Float64[1.0]); @inputs (; dt = 0.1))
        new_vel = velocity - state * dt
        new_state = state + new_vel * dt
        push!(trajectory, new_state)
        return (; state = new_state, velocity = new_vel)
    end

    @ProcessAlgorithm function Damper(state, velocity, trajectory, @managed(damp = 0.05))
        velocity = velocity * (1.0 - damp)
        push!(trajectory, state)
        return (; velocity)
    end

    shared_algo = @CompositeAlgorithm begin
        @alias osc = Oscillator
        osc()
        Damper(@all(osc...))
    end

    p = Process(shared_algo, repeats = 20, Input(Oscillator, :dt => 0.1))
    run(p)
    wait(p)

    actual_traj = StatefulAlgorithms.context(p)[Oscillator].trajectory
    @test length(actual_traj) == 41  # 1 initial + 2 pushes per step for 20 steps

    # Build expected trajectory assuming:
    # - Damper sees Oscillator's `state` and `trajectory`
    # - Damper's returned `velocity` updates the shared velocity used by Oscillator next step
    state = 1.0
    velocity = 0.0
    dt = 0.1
    damp = 0.05
    expected_traj = Float64[1.0]
    for _ in 1:20
        new_vel = velocity - state * dt
        new_state = state + new_vel * dt
        push!(expected_traj, new_state) # Oscillator push
        state = new_state
        velocity = new_vel

        velocity = velocity * (1.0 - damp)
        push!(expected_traj, state) # Damper push (shared trajectory)
    end

    @test isapprox(actual_traj, expected_traj; rtol = 0.0, atol = 1e-12)
end

