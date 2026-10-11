using Test
using StatefulAlgorithms

# A step reads and writes a declared local only through a wire into it (`Route(:_declared_locals => Algo, :name => :name)`):
# it reads the local under that name, and what it `@update`s under that name is written back through the wire.
# Algorithms of this file, defined at top level (defined inside a `@testset`, a plan allocates per step).
# A writer takes the local as a keyword and `@update`s it; a reader takes it as a positional argument.
@StepAlgorithm function LocalSensor(@managed(n = 0); reading = nothing)
    @update n += 1
    @update reading = n   # Int, declared Float64
end
@StepAlgorithm function LocalReader(reading, @managed(acc = 0.0))
    @update acc += reading
end

@StepAlgorithm function UnionSensor(@managed(n = 0); reading = nothing)
    @update n += 1
    @update reading = Float64(n)
end
@StepAlgorithm function UnionReader(reading, @managed(acc = 0.0))
    @update acc += reading === nothing ? 0.0 : reading
end
@StepAlgorithm function Blinker(@managed(n = 0); reading = nothing)
    @update reading = isodd(n) ? nothing : Float64(n)
    @update n += 1
end

@StepAlgorithm function SlotReader(reading, @managed(acc = 0.0))
    @update acc += reading
end

@StepAlgorithm function ScopeInc(counter)
    @update counter += 1
end
@StepAlgorithm function ScopeOutside(counter, @managed(seen = -1))
    @update seen = counter
end
@StepAlgorithm function ScopePeek(counter, @managed(seen = -1))
    @update seen = counter
end

# Reads its own local: starts as `nothing`, then is written back with the same type.
@StepAlgorithm function KeepLowest(best, @managed(n = 0))
    @update best = best === nothing ? Float64(n) : min(best, Float64(n))
    @update n += 1
end
@StepAlgorithm function ChangesType(x)
    @update x = x === nothing ? 1.0 : "changed"
end

@StepAlgorithm function OutputCollector(v, @managed(seen = Any[]))
    push!(seen, v)
    return
end

@testset "Declared loop locals (Local)" begin
    # Producer first runs on step 10; the reader holds the last value (the declared 0.0 before that).
    plan = CompositeAlgorithm(LocalSensor, LocalReader, (10, 1), Declaration(reading = 0.0), Route(:_declared_locals => LocalSensor, :reading => :reading), Route(:_declared_locals => LocalReader, :reading => :reading))
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

@testset "Declaring: Local(:x), Local(:x => T), Declaration(x = v); only wired algorithms see a local" begin
    @test StatefulAlgorithms.getvalues(Local(:x)).x === undef
    @test StatefulAlgorithms.getvalues(Local(:x => Float64)).x isa StatefulAlgorithms.Maybe{Float64}
    @test StatefulAlgorithms.getvalues(Declaration(x = 0.0)).x === 0.0
    err = try; Local(x = 0.0); nothing; catch e; e; end
    @test err isa ErrorException && occursin("A starting value is a `Declaration(x = …)`", sprint(showerror, err))

    # A reader without a wire into the local does not see it: `context.reading` is not one of its names.
    plan = CompositeAlgorithm(LocalSensor, LocalReader, (1, 1), Declaration(reading = 0.0), Route(:_declared_locals => LocalSensor, :reading => :reading))
    @test_throws Exception run(InlineProcess(plan; repeats = 2))
end

@testset "Declared locals keep their declared field type" begin
    declared = NamedTuple{(:reading,), Tuple{Union{Nothing, Float64}}}((nothing,))
    plan = CompositeAlgorithm(UnionSensor, UnionReader, (10, 1), Declaration(declared), Route(:_declared_locals => UnionSensor, :reading => :reading), Route(:_declared_locals => UnionReader, :reading => :reading))
    final = run(InlineProcess(plan; repeats = 25))
    @test final[UnionReader].acc == 10 * 1.0 + 6 * 2.0
    @test fieldtype(typeof(StatefulAlgorithms.get_declared_locals(final)), :reading) <: StatefulAlgorithms.Maybe{Float64}


    # `reading = nothing` behaves the same: `nothing` until the first write, then a `Union{Nothing,Float64}`.
    final = run(InlineProcess(CompositeAlgorithm(UnionSensor, UnionReader, (10, 1), Declaration(reading = nothing), Route(:_declared_locals => UnionSensor, :reading => :reading), Route(:_declared_locals => UnionReader, :reading => :reading)); repeats = 25))
    @test final[UnionReader].acc == 10 * 1.0 + 6 * 2.0
    @test fieldtype(typeof(StatefulAlgorithms.get_declared_locals(final)), :reading) <: StatefulAlgorithms.Maybe{Float64}

    # Writing `nothing` again after a value is allowed, like in a Julia loop.
    final = run(InlineProcess(CompositeAlgorithm(Blinker, UnionReader, (1, 1), Declaration(declared), Route(:_declared_locals => Blinker, :reading => :reading), Route(:_declared_locals => UnionReader, :reading => :reading)); repeats = 6))
    @test final[UnionReader].acc == 0.0 + 2.0 + 4.0
    # `@update reading = isodd(n) ? nothing : x` does not infer to a concrete type,
    # so an untyped local cannot be typed from it: declare the type instead.
    @test_throws ErrorException run(InlineProcess(CompositeAlgorithm(Blinker, UnionReader, (1, 1), Declaration(reading = nothing), Route(:_declared_locals => Blinker, :reading => :reading), Route(:_declared_locals => UnionReader, :reading => :reading)); repeats = 6))
end

@testset "undef locals take the type of their first value" begin
    # Hand-written (deprecated interface): a `@StepAlgorithm` reads every argument each step, so it cannot write
    # an undef local without reading it, nor read one only under a condition.
    struct SlotSensor <: ProcessAlgorithm end
    StatefulAlgorithms.init(::SlotSensor, context) = (; n = 0)
    StatefulAlgorithms.step!(::SlotSensor, context) = (; n = context.n + 1, reading = context.n + 1.0)
    # Written in the first step.
    final = run(InlineProcess(CompositeAlgorithm(SlotSensor, SlotReader, (1, 1), Local(:reading), Route(:_declared_locals => SlotSensor, :reading => :reading), Route(:_declared_locals => SlotReader, :reading => :reading)); repeats = 10))
    @test final[SlotReader].acc == 55.0
    @test fieldtype(typeof(StatefulAlgorithms.get_declared_locals(final)), :reading) <: StatefulAlgorithms.Maybe{Float64}
    # First written at step 10 (scheduled later): the loop continues with the new type.
    final = run(InlineProcess(CompositeAlgorithm(SlotSensor, SlotReader, (10, 10), Local(:reading), Route(:_declared_locals => SlotSensor, :reading => :reading), Route(:_declared_locals => SlotReader, :reading => :reading)); repeats = 30))
    @test final[SlotReader].acc == 1.0 + 2.0 + 3.0
    # Reading before the first write throws.
    @test_throws UndefRefError run(InlineProcess(CompositeAlgorithm(SlotSensor, SlotReader, (10, 1), Local(:reading), Route(:_declared_locals => SlotSensor, :reading => :reading), Route(:_declared_locals => SlotReader, :reading => :reading)); repeats = 3))
end

@testset "undef locals written conditionally" begin
    # Hand-written (deprecated interface): a `@StepAlgorithm` reads every argument each step, so it cannot write
    # an undef local without reading it, nor read one only under a condition.
    # The writer only returns the local once a runtime condition holds.
    struct LateSensor <: ProcessAlgorithm end
    struct GuardedReader <: ProcessAlgorithm end
    StatefulAlgorithms.init(::LateSensor, context) = (; n = 0)
    StatefulAlgorithms.step!(::LateSensor, context) =
        context.n >= 4 ? (; n = context.n + 1, reading = context.n + 1.0) : (; n = context.n + 1)
    StatefulAlgorithms.init(::GuardedReader, context) = (; k = 0, acc = 0.0)
    StatefulAlgorithms.step!(::GuardedReader, context) = (; k = context.k + 1, acc = context.k >= 4 ? context.acc + context.reading : context.acc)

    plan = CompositeAlgorithm(LateSensor, GuardedReader, (1, 1), Local(:reading), Route(:_declared_locals => LateSensor, :reading => :reading), Route(:_declared_locals => GuardedReader, :reading => :reading))
    final = run(InlineProcess(plan; repeats = 8))
    @test final[GuardedReader].acc == 5.0 + 6.0 + 7.0 + 8.0
    @test fieldtype(typeof(StatefulAlgorithms.get_declared_locals(final)), :reading) <: StatefulAlgorithms.Maybe{Float64}

    # Once written, the loop allocates nothing per step.
    small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
    run(small); run(large)
    allocs_small = @allocated run(small); allocs_large = @allocated run(large)
    @test allocs_large - allocs_small < 1_000

    # A guarded read that never fires is fine when the local is never written.
    final = run(InlineProcess(CompositeAlgorithm(LateSensor, GuardedReader, (1, 1), Local(:reading), Route(:_declared_locals => LateSensor, :reading => :reading), Route(:_declared_locals => GuardedReader, :reading => :reading)); repeats = 4))
    @test final[GuardedReader].acc == 0.0

    # Like a Julia variable, the type comes from every value written: here an `Int` and a
    # `Float64` from two writers, promoted to `Float64` before the run starts.
    struct IntWriter <: ProcessAlgorithm end
    struct FractionWriter <: ProcessAlgorithm end
    StatefulAlgorithms.init(::IntWriter, context) = (;)
    StatefulAlgorithms.step!(::IntWriter, context) = (; reading = 1)
    StatefulAlgorithms.init(::FractionWriter, context) = (;)
    StatefulAlgorithms.step!(::FractionWriter, context) = (; reading = 2.5)
    final = run(InlineProcess(CompositeAlgorithm(IntWriter, FractionWriter, (1, 2), Local(:reading), Route(:_declared_locals => IntWriter, :reading => :reading), Route(:_declared_locals => FractionWriter, :reading => :reading)); repeats = 3))
    @test fieldtype(typeof(StatefulAlgorithms.get_declared_locals(final)), :reading) <: StatefulAlgorithms.Maybe{Float64}
    @test StatefulAlgorithms.get_declared_locals(final).reading.value === 1.0
end

@testset "Locals are scoped to the plan that declares them" begin
    inner() = Routine(ScopeInc, (3,), Declaration(counter = 0), Route(:_declared_locals => ScopeInc, :counter => :counter))

    # The declaration stays on its plan's wiring; it is not lifted to the root.
    plan = CompositeAlgorithm(inner(), ScopeOutside, (1, 1))
    @test isempty(StatefulAlgorithms.getoptions(resolve(plan)))
    # A sibling outside the declaring routine does not see it.
    @test_throws Exception run(InlineProcess(plan; repeats = 2))

    # Two instances of the same routine get one local each.
    final = run(InlineProcess(CompositeAlgorithm(inner(), inner(), (1, 1)); repeats = 2))
    @test values(StatefulAlgorithms.get_declared_locals(final)) == (6, 6)

    # The nearest declaration wins.
    shadowing = CompositeAlgorithm(Routine(ScopeInc, ScopePeek, (3, 1), Declaration(counter = 0), Route(:_declared_locals => ScopeInc, :counter => :counter), Route(:_declared_locals => ScopePeek, :counter => :counter)), ScopeOutside, (1, 1), Declaration(counter = 100), Route(:_declared_locals => ScopeOutside, :counter => :counter))
    final = run(InlineProcess(shadowing; repeats = 2))
    @test final[ScopeOutside].seen == 100
    @test final[ScopePeek].seen == 6
end

@testset "A local keeps its type after its first value" begin
    # Reads its own local: starts as `nothing`, then is written back with the same type. Fine.
    final = run(InlineProcess(CompositeAlgorithm(KeepLowest, (1,), Declaration(best = nothing), Route(:_declared_locals => KeepLowest, :best => :best)); repeats = 5))
    @test StatefulAlgorithms.get_declared_locals(final).best isa StatefulAlgorithms.Maybe{Float64}

    # Starts as a Float64, then written as a String: an error before the run, naming the local.
    err = try
        run(InlineProcess(CompositeAlgorithm(ChangesType, (1,), Declaration(x = nothing), Route(:_declared_locals => ChangesType, :x => :x)); repeats = 3)); nothing
    catch e
        e
    end
    @test err isa ErrorException
    message = sprint(showerror, err)
    @test occursin("`ChangesType_1` (ChangesType) takes the local `x` as input with type Float64 and emits it with a different type, String", message)
end

@testset "Outputs have one type in every step" begin
    # `y` is written every 3 steps, so it is `nothing` until step 3. A call passes it on as the captured return `v`,
    # which is then `nothing` in some steps and a Float64 in others; its slot is typed before the run as
    # Union{Nothing, Float64}, so the runtime context keeps one type.
    produced = Ref(0)
    produce() = (produced[] += 1; Float64(produced[]))
    pass_on(x) = x
    plan = CompositeAlgorithm(StatefulAlgorithms.Callable(produce, (), :y), StatefulAlgorithms.Callable(pass_on, (:y,), :v), OutputCollector,
        (3, 1, 1), Declaration(y = nothing), Route(:_captured_returns => OutputCollector, :v => :v))
    p = Process(plan; repeats = 7); run(p); wait(p)
    @test context(p)[OutputCollector].seen == [nothing, nothing, 1.0, 1.0, 1.0, 2.0, 2.0]
end

const scope_seen = Any[]
const scope_count = Ref(0)
scope_produce() = (scope_count[] += 1; Float64(scope_count[]))
scope_double(x) = 2x
scope_record(x) = (push!(scope_seen, x); nothing)

@testset "Every plan node is a scope" begin
    C = StatefulAlgorithms.Callable
    run_seen(plan, repeats) = (empty!(scope_seen); scope_count[] = 0; run(InlineProcess(plan; repeats)); copy(scope_seen))
    # A `Local` keeps the inner composites whole (an option-less one is flattened into its parent, and its scope with it).
    inner(children...) = CompositeAlgorithm(children..., ntuple(_ -> 1, length(children)), Declaration(q = 0))

    # An inner node sees the outer return `y` and captures its own `z`, stored as `z@2`.
    plan = CompositeAlgorithm(C(scope_produce, (), :y), inner(C(scope_double, (:y,), :z), C(scope_record, (:z,), ())), (1, 2))
    wiring = typeof(StatefulAlgorithms.getwiring(StatefulAlgorithms.getalgo(StatefulAlgorithms.getplan(resolve(plan)), 2)))
    @test StatefulAlgorithms.scope_returns(StatefulAlgorithms.node_scope(wiring)) == (y = :y, z = Symbol("z@2"))
    @test StatefulAlgorithms.node_resets(wiring).returns == (Symbol("z@2"),)
    @test run_seen(plan, 6) == [4.0, 8.0, 12.0]

    # Assigning a visible name in an inner node writes the outer slot.
    plan = CompositeAlgorithm(C(scope_produce, (), :y), inner(C(scope_double, (:y,), :y)), C(scope_record, (:y,), ()), (1, 2, 1))
    @test run_seen(plan, 4) == [1.0, 4.0, 3.0, 8.0]

    # A return lives for the step that assigns it: read in a step where it was not assigned, it is an error.
    plan = CompositeAlgorithm(C(scope_produce, (), :y), C(scope_record, (:y,), ()), (2, 1))
    @test_throws "`y` has no value in this step" run(InlineProcess(plan; repeats = 4))

    # An inner node's returns are not visible outside it.
    plan = CompositeAlgorithm(C(scope_produce, (), :y), inner(C(scope_double, (:y,), :z)), C(scope_record, (:z,), ()), (1, 2, 1))
    @test_throws ErrorException run(InlineProcess(plan; repeats = 2))

    # Two nested scopes passing returns down still compile to a loop without allocations.
    plan = CompositeAlgorithm(C(scope_produce, (), :y), inner(C(scope_double, (:y,), :z), inner(C(scope_double, (:z,), :w), C(identity, (:w,), :v))), (1, 1))
    small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
    run(small); run(large)
    @test (@allocated run(large)) == (@allocated run(small))
end
