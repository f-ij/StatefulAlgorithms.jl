# using Pkg
# Pkg.activate((@__DIR__ )*"/..")

using Test
using Random
using StatefulAlgorithms

@testset "Routes: Walker->InsertNoise updates Walker momentum" begin
    # Minimal reproduction of `manual tests/WalkerTest.jl` without print spam.

    # `dt` is read from the init-time inputs
    @StepAlgorithm function Walker(
        @managed(state = (s = Float64[1.0]; StatefulAlgorithms.processsizehint!(s, context); s), momentum = 1.0, dt),
    )
        push!(state, state[end] + momentum * dt)
        return
    end

    # Adds noise to the routed `targetnum` (the walker's momentum)
    @StepAlgorithm @config seed::Int64 = 1234 function InsertNoise(targetnum, scale, @managed(rng = MersenneTwister(1234)))
        T = typeof(targetnum)
        rand_num = (rand(rng, T) - T(0.5)) * T(2) * scale
        @update targetnum = targetnum + rand_num
    end

    algo = CompositeAlgorithm(
        Walker, InsertNoise,
        (1, 2),
        Route(Walker => InsertNoise, :momentum => :targetnum, :dt => :scale),
    )

    p = Process(algo, repeats = 10, Input(Walker, :dt => 0.01))
    run(p)
    wait(p)
    c = fetch(p)

    # Test for correct cleanup output
    @test c isa ProcessContext

    actual = StatefulAlgorithms.context(p)[Walker].state
    expected = [
        1.0,
        1.01,
        1.02,
        1.030007664202586,
        1.0400153284051719,
        1.0501224635132498,
        1.0602295986213277,
        1.0702422421047793,
        1.0802548855882308,
        1.0901816017078885,
        1.1001083178275463,
    ]

    @test isapprox(actual, expected; rtol = 0.0, atol = 1e-12)


    # Route functions test
    # Two loggers told apart by their `name`
    @StepAlgorithm @config name::Symbol = :normal function RouteLogger(targetnum, @managed(log = Any[]))
        push!(log, targetnum)
        return
    end

    Logger1 = RouteLogger(:normal)
    Logger2 = RouteLogger(:squared)

    algo2 = CompositeAlgorithm(
        Walker, InsertNoise, Logger1, Logger2,
        (1, 2, 1, 1),
        Route(Walker => InsertNoise, :momentum => :targetnum, :dt => :scale),
        Route(Walker => Logger1, :state => :targetnum, transform = x-> x[end]),
        Route(Walker => Logger2, :state => :targetnum, transform = x-> x[end]^2),
    )

    p2 = Process(algo2, repeats = 10, Input(Walker, :dt => 0.01))
    run(p2)
    c2 = fetch(p2)

    log1 = c2[Logger1].log
    log2 = c2[Logger2].log
    @test all((log1 .^ 2) .== log2)

    # Reverse transforms let algorithm-facing route aliases write back through
    # the inverse mapping to their backing source fields.
    @StepAlgorithm function ReverseRouteSource(@managed(value = 1.0))
        return
    end
    @StepAlgorithm function ReverseRouteTarget(input)
        @update input = input + 2.0
    end

    reverse_algo = CompositeAlgorithm(
        ReverseRouteSource,
        ReverseRouteTarget,
        (1, 1),
        Route(
            ReverseRouteSource => ReverseRouteTarget,
            :value => :input;
            transform = x -> 2x,
            reverse_transform = x -> x / 2,
        ),
    )

    reverse_process = Process(reverse_algo, repeats = 1)
    run(reverse_process)
    reverse_context = fetch(reverse_process)
    @test reverse_context[ReverseRouteSource].value == 2.0

    @StepAlgorithm function ReverseTupleRouteSource(@managed(x = 1, y = 2))
        return
    end
    @StepAlgorithm function ReverseTupleRouteTarget(total)
        @update total = total + 5
    end

    reverse_tuple_algo = CompositeAlgorithm(
        ReverseTupleRouteSource,
        ReverseTupleRouteTarget,
        (1, 1),
        Route(
            ReverseTupleRouteSource => ReverseTupleRouteTarget,
            (:x, :y) => :total;
            transform = (x, y) -> x + y,
            reverse_transform = total -> (; x = total - 4, y = 4),
        ),
    )

    reverse_tuple_process = Process(reverse_tuple_algo, repeats = 1)
    run(reverse_tuple_process)
    reverse_tuple_context = fetch(reverse_tuple_process)
    @test reverse_tuple_context[ReverseTupleRouteSource].x == 4
    @test reverse_tuple_context[ReverseTupleRouteSource].y == 4

    missing_reverse_location = StatefulAlgorithms.VarLocation{:state}(:source, :value, x -> 2x)
    @test_throws ErrorException StatefulAlgorithms._build_write_request_exprs(missing_reverse_location, :input)

end
