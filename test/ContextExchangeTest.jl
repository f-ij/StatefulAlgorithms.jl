# UNUSED AT THE MOMENT (see the top of src/Interactive/ContextExchange.jl): these tests keep `ContextExchange` working
# while nothing uses it. Manual steps go through `exchange_stepper`, which keeps one loop cursor as a running loop does.
using Test
using StatefulAlgorithms

"""
    exchange_stepper(algo, context)

A function that steps `algo` once per call, keeping one loop cursor across calls as a running loop does, so children
on intervals run on their own ticks. (`StatefulAlgorithms._step!(algo, context)` starts a fresh cursor every call,
so a child on interval 2 never runs.)
"""
function exchange_stepper(algo, context)
    SA = StatefulAlgorithms
    lifetime = SA.Indefinite()
    session = SA.InlineSession()
    plan = SA.getplan(algo)
    cursor = SA.loop_cursor(plan, Val(false))
    runtime_context = SA._empty_context()
    wiring = SA.PlanWiringView(SA.getwiring(plan))
    return ctx -> SA.getpersistent(SA._step!(plan, cursor, SA.LoopContext(ctx, runtime_context), wiring, SA.Namespace{nothing}(), session, lifetime))
end

@testset "ContextExchange buffers interactive updates" begin
    @StepAlgorithm function ExchangeTargetForTest(@managed(value = 1.0, count = 1))
        return
    end

    algo = resolve(CompositeAlgorithm(
        :target => ExchangeTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 2),
    ))
    context = StatefulAlgorithms.context(init(algo, Init(:_exchange; vars = (Var(:target, :value),)); lifetime = Repeat(5)))

    interact!(context, :value => 2)
    exchange_key = getkey(only(StatefulAlgorithms._context_exchanges(context)))
    @test keys(context[exchange_key]) == (:store,)
    @test context[exchange_key].store.published.value isa Base.RefValue{Float64}
    @test context[exchange_key].store.pending.value isa Base.RefValue{Float64}
    @test context[exchange_key].store.haspending.value isa Base.RefValue{Bool}
    @test context[exchange_key].store.pending.value[] == 2.0
    @test context[exchange_key].store.haspending.value[]

    step_algo = exchange_stepper(algo, context)
    context = step_algo(context)
    @test context.target.value == 1.0
    @test context[exchange_key].store.pending.value[] == 2.0
    @test context[exchange_key].store.haspending.value[]

    context = step_algo(context)
    @test context.target.value == 2.0
    @test !context[exchange_key].store.haspending.value[]
end

@testset "InteractiveVar writes through ContextExchange" begin
    @StepAlgorithm function InteractiveVarTargetForTest(@managed(value = 1.0))
        return
    end

    algo = resolve(CompositeAlgorithm(
        :target => InteractiveVarTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 1),
    ))
    context = StatefulAlgorithms.context(init(algo, Init(:_exchange; vars = (Var(:target, :value),)); lifetime = Repeat(3)))

    ref = view(context, :value)
    @test ref[] == 1.0
    @test @inferred(ref[]) == 1.0
    exchange_key = getkey(only(StatefulAlgorithms._context_exchanges(context)))
    duplicate_ref = view(context, Var(exchange_key, :value))

    ref[] = 4
    @test ref[] == 1.0
    @test duplicate_ref[] == 1.0
    @test context[exchange_key].store.pending.value[] == 4.0
    @test context[exchange_key].store.haspending.value[]

    step_algo = exchange_stepper(algo, context)
    context = step_algo(context)
    @test context.target.value == 4.0
    @test ref[] == 4.0
    @test duplicate_ref[] == 4.0
    @test !context[exchange_key].store.haspending.value[]

    typed_ref = view(context, :value)
    typed_ref[] = 5
    context = step_algo(context)
    @test typed_ref[] == 5.0
end

@testset "InteractiveVar polls ContextExchange state" begin
    @StepAlgorithm function PollingInteractiveTargetForTest(@managed(value = 1, seen = 0))
        @update seen = seen + 1
    end

    algo = resolve(CompositeAlgorithm(
        :target => PollingInteractiveTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 1),
    ))
    context = StatefulAlgorithms.context(init(algo, Init(:_exchange; vars = (Var(:target, :seen),)); lifetime = Repeat(3)))

    seen_ref = view(context, :seen)
    @test seen_ref[] == 0

    step_algo = exchange_stepper(algo, context)
    context = step_algo(context)
    @test context.target.seen == 1
    @test seen_ref[] == 1

    interval_algo = resolve(CompositeAlgorithm(
        :target => PollingInteractiveTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 2),
    ))
    interval_context = StatefulAlgorithms.context(init(interval_algo, Init(:_exchange; vars = (Var(:target, :seen),)); lifetime = Repeat(4)))
    interval_ref = view(interval_context, :seen)

    step_interval_algo = exchange_stepper(interval_algo, interval_context)
    interval_context = step_interval_algo(interval_context)
    @test interval_context.target.seen == 1
    @test interval_ref[] == 0

    interval_context = step_interval_algo(interval_context)
    @test interval_context.target.seen == 2
    @test interval_ref[] == 2
end

@testset "ContextExchange supports aliases and type selectors" begin
    @StepAlgorithm function AliasedExchangeTargetForTest(@managed(value = 1.0))
        return
    end

    algo = resolve(CompositeAlgorithm(
        :target => AliasedExchangeTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 1),
    ))
    context = StatefulAlgorithms.context(init(
        algo,
        Init(:_exchange; vars = (:display => Var(AliasedExchangeTargetForTest, :value),));
        lifetime = Repeat(2),
    ))

    ref = view(context, :display)
    ref[] = 3
    step_algo = exchange_stepper(algo, context)
    context = step_algo(context)

    @test context.target.value == 3.0
    @test ref[] == 3.0
end

@testset "InteractiveVar requires a ContextExchange" begin
    @StepAlgorithm function NoExchangeTargetForTest(@managed(value = 1.0))
        return
    end

    algo = resolve(CompositeAlgorithm(:target => NoExchangeTargetForTest(), (1,)))
    context = initcontext(algo; lifetime = Repeat(1))

    @test_throws ErrorException view(context, :value)
end

@testset "ContextExchange timer skips reads and writes" begin
    @StepAlgorithm function TimedExchangeTargetForTest(@managed(value = 1.0, seen = 0))
        @update seen = seen + 1
    end

    algo = resolve(CompositeAlgorithm(
        :target => TimedExchangeTargetForTest(),
        :_exchange => ContextExchange(; period = 60.0),
        (1, 1),
    ))
    context = StatefulAlgorithms.context(init(
        algo,
        Init(:_exchange; vars = (Var(:target, :value), Var(:target, :seen)));
        lifetime = Repeat(3),
    ))
    value_ref = view(context, :value)
    seen_ref = view(context, :seen)

    step_algo = exchange_stepper(algo, context)
    context = step_algo(context)
    @test value_ref[] == 1.0
    @test seen_ref[] == 1

    value_ref[] = 4
    context = step_algo(context)
    @test context.target.value == 1.0
    @test value_ref[] == 1.0
    @test seen_ref[] == 1
end

@testset "ContextExchange updates running process state" begin
    @StepAlgorithm function SlowInteractiveTargetForTest(@managed(value = 1, seen = 0))
        sleep(0.01)
        @update seen = seen + 1
    end

    algo = resolve(CompositeAlgorithm(
        :target => SlowInteractiveTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 1),
    ))
    process = Process(algo, Init(:_exchange; vars = (Var(:target, :value),)); repeat = Inf)

    run(process)

    started_deadline = time() + 2.0
    while loopint(process) < 3 && time() < started_deadline
        sleep(0.005)
    end
    @test loopint(process) >= 3

    ref = view(context(process), :value)
    ref[] = 42

    injected_deadline = time() + 2.0
    while loopint(process) < 6 && time() < injected_deadline
        sleep(0.005)
    end

    close(process)
    @test context(process).target.value == 42
    @test context(process).target.seen > 0
end
