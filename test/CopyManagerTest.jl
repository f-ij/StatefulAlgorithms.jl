using Test
using StatefulAlgorithms

# Pushes `value` to `sink`, then adds `delta` to it; `value` starts at the input `start`.
@StepAlgorithm function CopyManagedAccumulator(delta, @managed(value = start, sink); @init((; start)))
    push!(sink, value)
    @update value = value + delta
end

@testset "copyprocess rebuilds from task description" begin
    template_sink = Int[]
    template = Process(
        CopyManagedAccumulator,
        Input(CopyManagedAccumulator, :start => 1, :sink => template_sink),
        Override(CopyManagedAccumulator, :delta => 2);
        repeats = 3,
    )

    sink_a = Int[]
    sink_b = Int[]

    p_a = copyprocess(
        template,
        Input(CopyManagedAccumulator, :start => 10, :sink => sink_a),
    )
    p_b = copyprocess(
        template,
        Input(CopyManagedAccumulator, :start => 20, :sink => sink_b),
    )

    run(p_a)
    run(p_b)

    wait(p_a)
    wait(p_b)

    close(p_a)
    close(p_b)

    ctx_a = context(p_a)
    ctx_b = context(p_b)

    @test sink_a == [10, 12, 14]
    @test sink_b == [20, 22, 24]
    @test isempty(template_sink)
    @test ctx_a[CopyManagedAccumulator].value == 16
    @test ctx_b[CopyManagedAccumulator].value == 26
end
