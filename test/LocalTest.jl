using Test
using StatefulAlgorithms

@testset "Declared loop locals (Local)" begin
    struct LocalSensor <: ProcessAlgorithm end
    struct LocalReader <: ProcessAlgorithm end
    StatefulAlgorithms.init(::LocalSensor, context) = (; n = 0)
    StatefulAlgorithms.step!(::LocalSensor, context) = (; n = context.n + 1, reading = context.n + 1)   # Int, declared Float64
    StatefulAlgorithms.init(::LocalReader, context) = (; acc = 0.0)
    StatefulAlgorithms.step!(::LocalReader, context) = (; acc = context.acc + context.reading)

    # Producer first runs on step 10; the reader holds the last value (the declared 0.0 before that).
    plan = CompositeAlgorithm(LocalSensor, LocalReader, (10, 1), Local(reading = 0.0))
    ip = InlineProcess(plan; repeats = 25); run(ip)
    @test context(ip)[LocalReader].acc == 9 * 0.0 + 10 * 1.0 + 6 * 2.0

    # Shape stays fixed: no per-step allocation even though the producer is conditional.
    run(InlineProcess(plan; repeats = 100))
    small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
    allocs_small = @allocated run(small); allocs_large = @allocated run(large)
    @test allocs_large - allocs_small < 1_000

    # Returned values are converted to the declared type.
    p = Process(plan; repeats = 30); run(p); wait(p)
    @test context(p)[LocalReader].acc isa Float64
end

@testset "Declared locals keep their declared field type" begin
    struct UnionSensor <: ProcessAlgorithm end
    struct UnionReader <: ProcessAlgorithm end
    StatefulAlgorithms.init(::UnionSensor, context) = (; n = 0)
    StatefulAlgorithms.step!(::UnionSensor, context) = (; n = context.n + 1, reading = Float64(context.n + 1))
    StatefulAlgorithms.init(::UnionReader, context) = (; acc = 0.0)
    StatefulAlgorithms.step!(::UnionReader, context) = (; acc = context.acc + (context.reading === nothing ? 0.0 : context.reading))

    declared = NamedTuple{(:reading,), Tuple{Union{Nothing, Float64}}}((nothing,))
    plan = CompositeAlgorithm(UnionSensor, UnionReader, (10, 1), Local(declared))
    final = run(InlineProcess(plan; repeats = 25))
    @test final[UnionReader].acc == 10 * 1.0 + 6 * 2.0
    @test fieldtype(typeof(StatefulAlgorithms.getlocals(final)), :reading) == Union{Nothing, Float64}

    @test_throws Exception run(InlineProcess(CompositeAlgorithm(UnionSensor, UnionReader, (10, 1), Local(reading = nothing)); repeats = 25))
end
