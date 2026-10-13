using Test
using StatefulAlgorithms
using StatefulAlgorithms: Callable, Literal, Splat   # internal: tests build calls directly

@StepAlgorithm function ExSensor(@managed(state = 0.0))
    @update state += 1.0
end

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

run_locals(plan; repeats = 3) = StatefulAlgorithms.get_declared_locals(run(InlineProcess(plan; repeats)))

@testset "Callable: calls with a signature in plan names" begin
    # Reads and writes a declared local.
    @test run_locals(CompositeAlgorithm(Callable(ex_bump, (:n,), :n), (1,), Declaration(n = 0))).n == 3

    # Callable structs and closures are called the same way.
    offset = 10.0
    plan = CompositeAlgorithm(Callable(ExScale(2.0), (:x,), :y), Callable(v -> v + offset, (:y,), :z), (1, 1), Declaration(x = 1.0, y = 0.0, z = 0.0))
    @test run_locals(plan).z == 12.0

    # Keywords: from plan names (`f(; scale)` / `f(scale = s)`), literals, and literal symbols.
    plan = CompositeAlgorithm(Callable(ex_kw, (:x,), (; scale = :s, offset = 0.5), :y), (1,), Declaration(x = 2.0, s = 3.0, y = 0.0))
    @test run_locals(plan).y == 6.5
    plan = CompositeAlgorithm(Callable(ex_mode, (:x,), (; mode = Literal(:double)), :y), (1,), Declaration(x = 2.0, y = 0.0))
    @test run_locals(plan).y == 4.0

    # Splatting: positional and keyword.
    plan = CompositeAlgorithm(Callable(ex_sum, (Splat(:xs),), (Splat(:opts),), :y), (1,), Declaration(xs = (1, 2, 3), opts = (; extra = 10), y = 0))
    @test run_locals(plan).y == 16

    # Returns: unpack, collect the rest, properties with renaming, side effects only.
    @test run_locals(CompositeAlgorithm(Callable(ex_pair, (:x,), (:a, :b)), (1,), Declaration(x = 1, a = 0, b = 0))) == (x = 1, a = 1, b = 2)
    locals = run_locals(CompositeAlgorithm(Callable(ex_pair, (:x,), (:a, Splat(:rest))), (1,), Declaration(x = 1, a = 0, rest = (0, 0))))
    @test locals.rest == (2, 3)
    locals = run_locals(CompositeAlgorithm(Callable(ex_named, (:x,), (; low = :lo, high = :hi)), (1,), Declaration(x = 5, lo = 0, hi = 0)))
    @test (locals.lo, locals.hi) == (4, 6)
    seen = Ref(0)
    run(InlineProcess(CompositeAlgorithm(Callable(x -> (seen[] += x; nothing), (:x,), ()), (1,), Declaration(x = 2)); repeats = 3))
    @test seen[] == 6

    # Return types: a wrong type is an error, never a conversion.
    @test run_locals(CompositeAlgorithm(Callable(ex_bump, (:n,), :n => Int), (1,), Declaration(n = 0))).n == 3
    @test_throws TypeError run(InlineProcess(CompositeAlgorithm(Callable(ex_bump, (:n,), :n => Float64), (1,), Declaration(n = 0)); repeats = 1))

    # The output of one call is readable by a later one without a declaration (shared `_captured_returns` bucket).
    plan = CompositeAlgorithm(Callable(ex_bump, (:n,), :m), Callable(ex_bump, (:m,), :n), (1, 1), Declaration(n = 0))
    @test run_locals(plan).n == 6
end

@testset "Callable: no identity, no registry entry, one type per signature" begin
    @test typeof(Callable(ex_bump, (:n,), :n)) === typeof(Callable(ex_bump, (:n,), :n))
    plan = CompositeAlgorithm(ExSensor, Callable(ex_bump, (:n,), :n), (1, 1), Declaration(n = 0))
    resolved = resolve(plan)
    @test StatefulAlgorithms.plan_child_namespace(resolved, 2) === :_captured_returns
    @test keys(StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.ProcessContext(resolved))) == (:ExSensor_1,)

    # Zero allocations per step.
    small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
    run(small); run(large)
    small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
    @test (@allocated run(large)) - (@allocated run(small)) < 1_000
end

@testset "WithWiring: wiring attached to one child by position" begin
    # Read an algorithm's state under a different name in a call.
    plan = CompositeAlgorithm(ExSensor, WithWiring(Callable(ExScale(10.0), (:x,), :y), From(Var(ExSensor, :state) => :x)), (1, 1), Declaration(y = 0.0))
    @test run_locals(plan).y == 30.0

    # Two identical calls wired differently.
    plan = CompositeAlgorithm(ExSensor,
                              WithWiring(Callable(ex_bump, (:x,), :a), From(Var(ExSensor, :state) => :x)),
                              WithWiring(Callable(ex_bump, (:x,), :b), From(Var(:_declared_locals, :a) => :x)),
                              (1, 1, 1), Declaration(a = 0.0, b = 0.0))
    @test values(run_locals(plan)) == (4.0, 5.0)

    # On an algorithm child: rename what it reads.
    @StepAlgorithm function ExReader(reading, @managed(seen = 0.0))
        @update seen = reading
    end
    plan = CompositeAlgorithm(ExSensor, WithWiring(ExReader, From(Var(ExSensor, :state) => :reading)), (1, 1))
    @test run(InlineProcess(plan; repeats = 3))[ExReader].seen == 3.0
end

ex_twice(x) = 2x
ex_final(context) = (; y = context.y, z = context.z)

@testset "Var: transform, and as the source of a wire" begin
    # A transformed wire: read ExSensor's `state` as x + 100.
    plan = CompositeAlgorithm(ExSensor, WithWiring(Callable(ex_twice, (:x,), :y), From(Var(ExSensor, :state; transform = v -> v + 100) => :x)), (1, 1), Declaration(y = 0.0))
    @test run_locals(plan).y == 206.0
    # Reading a Var with a transform from a context.
    final = run(InlineProcess(CompositeAlgorithm(ExSensor, (1,)); repeats = 3))
    @test final[Var(ExSensor, :state; transform = v -> 10v)] == 30.0
end

@testset "DSL calls lower to Callables, wired with WithWiring" begin
    algo = @CompositeAlgorithm begin
        @alias sensor = ExSensor()
        sensor()
        y = ex_twice(sensor.state)                       # an algorithm's field: a wire
        z = ex_twice(@transform(v -> v + 1, sensor.state)) # a transformed field: a wire with a transform
        @finally ex_final
    end
    resolved = resolve(algo)
    plan = StatefulAlgorithms.getplan(resolved)
    @test all(i -> StatefulAlgorithms.getalgo(plan, i) isa Callable, 2:3)
    slot(i) = StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(plan))[i]
    @test length(StatefulAlgorithms.routes(slot(2))) == 1
    @test StatefulAlgorithms.gettransform(only(StatefulAlgorithms.routes(slot(3)))) !== nothing
    p = Process(resolved, repeat = 2); run(p)
    @test fetch(p) == (; y = 4.0, z = 6.0)

    # Plain names and values need no wires.
    algo = @CompositeAlgorithm begin
        @state seed = 1.0
        a = ex_twice(seed)
        b = ex_kw(a; scale = 3.0)
        @finally context -> (; b = context.b)
    end
    plan = StatefulAlgorithms.getplan(resolve(algo))
    @test StatefulAlgorithms.getalgo(plan, 2) isa Callable
    @test isempty(StatefulAlgorithms.routes(StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(plan))[2]))
    p = Process(resolve(algo), repeat = 1); run(p)
    @test fetch(p) == (; b = 6.0)

end

@StepAlgorithm function VarPlain(@managed(x = 0.0))
    @update x += 1.0
end
# Holds a Vector, so not plain data.
@StepAlgorithm @config buf::Vector{Float64} = zeros(3) function VarBuffered(@managed(x = 0.0))
    @update x += 2.0
end

@testset "Var reads from contexts, by type, instance, key and transform" begin
    b = VarBuffered(zeros(3))
    plan = CompositeAlgorithm(VarPlain, b, (1, 1))
    final = run(InlineProcess(plan; repeats = 3))
    @test final[Var(VarPlain, :x)] == 3.0                      # owner entered as a type
    @test final[Var(b, :x)] == 6.0                             # owner entered as an instance with a Vector
    @test final[Var(b, :x; transform = v -> 10v)] == 60.0
    key = StatefulAlgorithms.plan_child_namespace(resolve(plan), 2)
    @test final[Var(key, :x)] == 6.0                           # owner given by its context key
    @test final[Var(VarPlain, :x), Var(b, :x)] == (3.0, 6.0)

    # As a lifetime condition.
    stopped = run(InlineProcess(plan; lifetime = Until(x -> x >= 10, Var(b, :x))))
    @test stopped[Var(b, :x)] == 10.0

    # As the source of a wire.
    wired = CompositeAlgorithm(b, WithWiring(Callable(ex_twice, (:v,), :y), From(Var(b, :x) => :v)), (1, 1), Declaration(y = 0.0))
    @test run_locals(wired).y == 12.0
end
