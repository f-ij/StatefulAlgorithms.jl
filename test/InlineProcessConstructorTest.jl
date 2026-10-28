using Test
using StatefulAlgorithms

@testset "InlineProcess constructor matches Process inputs and overrides" begin
    @StepAlgorithm function InlineAccumulator(@managed(value = start, delta = 0); @init((; start)))
        @update value += delta
    end

    ip = InlineProcess(
        InlineAccumulator,
        Input(InlineAccumulator, :start => 3),
        Override(InlineAccumulator, :delta => 2);
        lifetime = 4,
    )

    ctx = run(ip)

    @test ctx[InlineAccumulator].delta == 2
    @test loopidx(ip) == 5
    @test ctx[InlineAccumulator].value == 11
end

@testset "InlineProcess run with the loop pasted in matches the called loop" begin
    @StepAlgorithm function InlinedCounter(@managed(count = 0))
        @update count += 1
    end
    a, b = Unique(InlinedCounter()), Unique(InlinedCounter())
    stop(c) = c >= 7
    make() = InlineProcess(CompositeAlgorithm(a, b, (1, 2)); lifetime = RepeatOrUntil(stop, 100, Var(a, :count)))
    called, pasted = make(), make()
    ctx_called = run(called)
    ctx_pasted = run(pasted; inlined = Val(true))
    @test ctx_pasted[a].count == ctx_called[a].count == 7
    @test ctx_pasted[b].count == ctx_called[b].count
    @test loopidx(pasted) == loopidx(called)
    # A second run goes on from the kept context on both paths.
    @test run(pasted; inlined = Val(true), lifetime = 3)[a].count == run(called; lifetime = 3)[a].count
end

@testset "Process constructor resolves inputs for algorithm types" begin
    @StepAlgorithm function TypeInputAccumulator(@managed(value = start); @init((; start)))
        @update value += 1
    end

    p = Process(
        TypeInputAccumulator,
        Input(TypeInputAccumulator, :start => 4);
        repeats = 2,
    )

    run(p)
    wait(p)
    close(p)

    @test context(p)[TypeInputAccumulator].value == 6

    unresolved = CompositeAlgorithm(TypeInputAccumulator)
    @test_throws ArgumentError StatefulAlgorithms.resolve_process_inputs_overrides(
        unresolved,
        (Input(TypeInputAccumulator, :start => 4),),
    )

    resolved = resolve(unresolved)
    specs = (Input(TypeInputAccumulator, :start => 4),)
    named_inputs, named_overrides = StatefulAlgorithms.resolve_process_inputs_overrides(
        resolved,
        specs,
    )
    @test length(named_inputs) == 1
    @test isempty(named_overrides)
    @test @inferred(StatefulAlgorithms.resolve_process_inputs_overrides(resolved, specs)) == (named_inputs, named_overrides)
end
