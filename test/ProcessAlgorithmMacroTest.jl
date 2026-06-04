using Test
using StatefulAlgorithms

@testset "ProcessAlgorithm macro inputs and managed capture" begin
    @ProcessAlgorithm function CaptureInput(
        a,
        @managed(c = b^2),
        @managed(b);
        @inputs((; b = 1))
    )
        b = b + a
        c = c + b
        return (; b, c, total = a + b + c)
    end

    prepared = StatefulAlgorithms.init(CaptureInput(), (; b = 3))
    @test prepared.b == 3
    @test prepared.c == 9

    stepped = StatefulAlgorithms.step!(CaptureInput(), (; a = 2, b = prepared.b, c = prepared.c))
    @test stepped.b == 5
    @test stepped.c == 14
    @test stepped.total == 21

    boot_inputs = StatefulAlgorithms.step!(CaptureInput(), 2; @inputs((; b = 4)))
    @test boot_inputs.b == 6
    @test boot_inputs.c == 22
    @test boot_inputs.total == 30

    boot_init = StatefulAlgorithms.step!(CaptureInput(), 2; @init((; b = 4)))
    @test boot_init == boot_inputs
end

@testset "ProcessAlgorithm macro keeps @init declaration compatibility" begin
    @ProcessAlgorithm function LegacyInputs(
        a,
        @managed(c = b + 1),
        @managed(b);
        @init((; b = 2))
    )
        return (; total = a + b + c)
    end

    prepared = StatefulAlgorithms.init(LegacyInputs(), (;))
    @test prepared.b == 2
    @test prepared.c == 3

    stepped = StatefulAlgorithms.step!(LegacyInputs(), (; a = 5, b = prepared.b, c = prepared.c))
    @test stepped.total == 10
end

@testset "ProcessAlgorithm macro can capture managed values directly from init context" begin
    @ProcessAlgorithm function ContextCapture(
        x,
        @managed(state),
        @managed(dt),
        @managed(velocity = 0.0);
        @input((; dt = 0.1))
    )
        return (; state = state + dt + velocity + x)
    end

    prepared = StatefulAlgorithms.init(ContextCapture(), (; state = 1.0))
    @test prepared.state == 1.0
    @test prepared.dt == 0.1
    @test prepared.velocity == 0.0

    stepped = StatefulAlgorithms.step!(ContextCapture(), (; x = 0.0, state = prepared.state, dt = prepared.dt, velocity = prepared.velocity))
    @test stepped.state == 1.1
end

@testset "ProcessAlgorithm macro supports grouped @managed declarations" begin
    @ProcessAlgorithm function GroupedManaged(
        a,
        @managed(b, c = b + 1, d = nothing);
        @inputs((; b = 2))
    )
        return (; total = a + b + c, d)
    end

    prepared = StatefulAlgorithms.init(GroupedManaged(), (;))
    @test prepared.b == 2
    @test prepared.c == 3
    @test isnothing(prepared.d)

    stepped = StatefulAlgorithms.step!(GroupedManaged(), (; a = 5, b = prepared.b, c = prepared.c, d = prepared.d))
    @test stepped.total == 10
    @test isnothing(stepped.d)
end

@testset "ProcessAlgorithm macro supports where signatures" begin
    resetstate!(graph::AbstractVector) = fill!(graph, 0)

    @ProcessAlgorithm function resetgraph!(isinggraph::G) where G
        resetstate!(isinggraph)
        return
    end

    graph = [1, 2, 3]
    StatefulAlgorithms.step!(resetgraph!(), graph)
    @test graph == [0, 0, 0]

    graph2 = [4, 5]
    StatefulAlgorithms.step!(resetgraph!(), (; isinggraph = graph2))
    @test graph2 == [0, 0]
end

@testset "ProcessAlgorithm macro supports @config-backed structs" begin
    @ProcessAlgorithm @config seed::Int = 3 begin
        @config begin
            width::Int = 2
        end
        function ConfiguredNoise(
            target,
            @managed(buffer = fill(seed, width));
            gain = 1,
            @inputs((;))
        )
            total = target + sum(buffer) + gain + seed + width
            return (; total, seed, width)
        end
    end

    algo = ConfiguredNoise(seed = 5, width = 4)
    @test algo.seed == 5
    @test algo.width == 4

    prepared = StatefulAlgorithms.init(algo, (;))
    @test prepared.buffer == fill(5, 4)

    direct = StatefulAlgorithms.step!(algo, 2; gain = 3)
    @test direct.total == 34
    @test direct.seed == 5
    @test direct.width == 4

    stepped = StatefulAlgorithms.step!(algo, (; target = 2, buffer = prepared.buffer, gain = 3))
    @test stepped == direct
end
