using Test
using StatefulAlgorithms

struct ExSensor <: ProcessAlgorithm end
StatefulAlgorithms.init(::ExSensor, context) = (; state = 0.0)
StatefulAlgorithms.step!(::ExSensor, context) = (; state = context.state + 1.0)

struct ExScale                       # a callable struct
    factor::Float64
end
(s::ExScale)(x) = s.factor * x

ex_bump(n) = n + 1
ex_kw(x; scale = 1.0, offset = 0.0) = scale * x + offset
ex_mode(x; mode) = mode === :double ? 2x : x
ex_sum(xs...; extra = 0) = sum(xs) + extra
ex_pair(x) = (x, 2x, 3x)
ex_named(x) = (; low = x - 1, high = x + 1)

run_locals(plan; repeats = 3) = StatefulAlgorithms.getlocals(run(InlineProcess(plan; repeats)))

@testset "Executable: calls with a signature in plan names" begin
    # Reads and writes a declared local.
    @test run_locals(CompositeAlgorithm(Executable(ex_bump, (:n,), :n), (1,), Local(n = 0))).n == 3

    # Callable structs and closures are called the same way.
    offset = 10.0
    plan = CompositeAlgorithm(Executable(ExScale(2.0), (:x,), :y), Executable(v -> v + offset, (:y,), :z), (1, 1), Local(x = 1.0, y = 0.0, z = 0.0))
    @test run_locals(plan).z == 12.0

    # Keywords: from plan names (`f(; scale)` / `f(scale = s)`), literals, and literal symbols.
    plan = CompositeAlgorithm(Executable(ex_kw, (:x,), (; scale = :s, offset = 0.5), :y), (1,), Local(x = 2.0, s = 3.0, y = 0.0))
    @test run_locals(plan).y == 6.5
    plan = CompositeAlgorithm(Executable(ex_mode, (:x,), (; mode = Literal(:double)), :y), (1,), Local(x = 2.0, y = 0.0))
    @test run_locals(plan).y == 4.0

    # Splatting: positional and keyword.
    plan = CompositeAlgorithm(Executable(ex_sum, (Splat(:xs),), (Splat(:opts),), :y), (1,), Local(xs = (1, 2, 3), opts = (; extra = 10), y = 0))
    @test run_locals(plan).y == 16

    # Returns: unpack, collect the rest, properties with renaming, side effects only.
    @test run_locals(CompositeAlgorithm(Executable(ex_pair, (:x,), (:a, :b)), (1,), Local(x = 1, a = 0, b = 0))) == (x = 1, a = 1, b = 2)
    locals = run_locals(CompositeAlgorithm(Executable(ex_pair, (:x,), (:a, Splat(:rest))), (1,), Local(x = 1, a = 0, rest = (0, 0))))
    @test locals.rest == (2, 3)
    locals = run_locals(CompositeAlgorithm(Executable(ex_named, (:x,), (; low = :lo, high = :hi)), (1,), Local(x = 5, lo = 0, hi = 0)))
    @test (locals.lo, locals.hi) == (4, 6)
    seen = Ref(0)
    run(InlineProcess(CompositeAlgorithm(Executable(x -> (seen[] += x; nothing), (:x,), ()), (1,), Local(x = 2)); repeats = 3))
    @test seen[] == 6

    # Return types: a wrong type is an error, never a conversion.
    @test run_locals(CompositeAlgorithm(Executable(ex_bump, (:n,), :n => Int), (1,), Local(n = 0))).n == 3
    @test_throws TypeError run(InlineProcess(CompositeAlgorithm(Executable(ex_bump, (:n,), :n => Float64), (1,), Local(n = 0)); repeats = 1))

    # The output of one call is readable by a later one without a declaration (shared `_runtime` bucket).
    plan = CompositeAlgorithm(Executable(ex_bump, (:n,), :m), Executable(ex_bump, (:m,), :n), (1, 1), Local(n = 0))
    @test run_locals(plan).n == 6
end

@testset "Executable: no identity, no registry entry, one type per signature" begin
    @test typeof(Executable(ex_bump, (:n,), :n)) === typeof(Executable(ex_bump, (:n,), :n))
    plan = CompositeAlgorithm(ExSensor, Executable(ex_bump, (:n,), :n), (1, 1), Local(n = 0))
    resolved = resolve(plan)
    @test StatefulAlgorithms.plan_child_namespace(resolved, 2) === :_runtime
    @test keys(StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.ProcessContext(resolved))) == (:ExSensor_1,)

    # Zero allocations per step.
    small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
    run(small); run(large)
    small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
    @test (@allocated run(large)) - (@allocated run(small)) < 1_000
end

@testset "WithWiring: wiring attached to one child by position" begin
    # Read an algorithm's state under a different name in a call.
    plan = CompositeAlgorithm(ExSensor, WithWiring(Executable(ExScale(10.0), (:x,), :y), From(ExSensor, :state => :x)), (1, 1), Local(y = 0.0))
    @test run_locals(plan).y == 30.0

    # Two identical calls wired differently.
    plan = CompositeAlgorithm(ExSensor,
                              WithWiring(Executable(ex_bump, (:x,), :a), From(ExSensor, :state => :x)),
                              WithWiring(Executable(ex_bump, (:x,), :b), From(:_local, :a => :x)),
                              (1, 1, 1), Local(a = 0.0, b = 0.0))
    @test values(run_locals(plan)) == (4.0, 5.0)

    # On an algorithm child: rename what it reads.
    struct ExReader <: ProcessAlgorithm end
    StatefulAlgorithms.init(::ExReader, context) = (; seen = 0.0)
    StatefulAlgorithms.step!(::ExReader, context) = (; seen = context.reading)
    plan = CompositeAlgorithm(ExSensor, WithWiring(ExReader, From(ExSensor, :state => :reading)), (1, 1))
    @test run(InlineProcess(plan; repeats = 3))[ExReader].seen == 3.0
end
