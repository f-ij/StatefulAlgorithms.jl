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
        InitArgs(CopyManagedAccumulator, :start => 1, :sink => template_sink),
        Override(CopyManagedAccumulator, :delta => 2);
        repeats = 3,
    )

    sink_a = Int[]
    sink_b = Int[]

    p_a = init!(copyprocess(template), InitArgs(CopyManagedAccumulator, :start => 10, :sink => sink_a))
    p_b = init!(copyprocess(template), InitArgs(CopyManagedAccumulator, :start => 20, :sink => sink_b))
    @test_throws MethodError copyprocess(template, InitArgs(CopyManagedAccumulator, :start => 30))
    # `context`: the copy starts from those values, no `init` runs; another shape is refused
    from_context = copyprocess(template; context = deepcopy(getcontext(template)))
    @test getcontext(from_context)[CopyManagedAccumulator].value == 1
    @test StatefulAlgorithms.getspecs(from_context) == StatefulAlgorithms.getspecs(template)
    other_shape = Process(CopyManagedAccumulator, InitArgs(CopyManagedAccumulator, :start => 1.5, :sink => Float64[]), Override(CopyManagedAccumulator, :delta => 2.0); repeats = 3)
    @test typeof(getcontext(other_shape)) !== typeof(getcontext(template))
    @test_throws ArgumentError copyprocess(template; context = getcontext(other_shape))
    close(other_shape)

    run(p_a)
    run(p_b)

    wait(p_a)
    wait(p_b)

    close(p_a)
    close(p_b)

    ctx_a = getcontext(p_a)
    ctx_b = getcontext(p_b)

    @test sink_a == [10, 12, 14]
    @test sink_b == [20, 22, 24]
    @test isempty(template_sink)
    @test ctx_a[CopyManagedAccumulator].value == 16
    @test ctx_b[CopyManagedAccumulator].value == 26
end
