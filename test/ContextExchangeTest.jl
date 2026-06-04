using Test
using StatefulAlgorithms

@testset "ContextExchange buffers interactive updates" begin
    struct ExchangeTargetForTest <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::ExchangeTargetForTest, context)
        return (; value = 1.0, count = 1)
    end

    function StatefulAlgorithms.step!(::ExchangeTargetForTest, context)
        return (;)
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

    context = StatefulAlgorithms._step!(algo, context)
    @test context.target.value == 1.0
    @test context[exchange_key].store.pending.value[] == 2.0
    @test context[exchange_key].store.haspending.value[]

    context = StatefulAlgorithms._step!(algo, context)
    @test context.target.value == 2.0
    @test !context[exchange_key].store.haspending.value[]
end

@testset "InteractiveVar writes through ContextExchange" begin
    struct InteractiveVarTargetForTest <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::InteractiveVarTargetForTest, context)
        return (; value = 1.0)
    end

    function StatefulAlgorithms.step!(::InteractiveVarTargetForTest, context)
        return (;)
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

    context = StatefulAlgorithms._step!(algo, context)
    @test context.target.value == 4.0
    @test ref[] == 4.0
    @test duplicate_ref[] == 4.0
    @test !context[exchange_key].store.haspending.value[]

    typed_ref = view(context, :value)
    typed_ref[] = 5
    context = StatefulAlgorithms._step!(algo, context)
    @test typed_ref[] == 5.0
end

@testset "InteractiveVar polls ContextExchange state" begin
    struct PollingInteractiveTargetForTest <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::PollingInteractiveTargetForTest, context)
        return (; value = 1, seen = 0)
    end

    function StatefulAlgorithms.step!(::PollingInteractiveTargetForTest, context)
        return (; seen = context.seen + 1)
    end

    algo = resolve(CompositeAlgorithm(
        :target => PollingInteractiveTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 1),
    ))
    context = StatefulAlgorithms.context(init(algo, Init(:_exchange; vars = (Var(:target, :seen),)); lifetime = Repeat(3)))

    seen_ref = view(context, :seen)
    @test seen_ref[] == 0

    context = StatefulAlgorithms._step!(algo, context)
    @test context.target.seen == 1
    @test seen_ref[] == 1

    interval_algo = resolve(CompositeAlgorithm(
        :target => PollingInteractiveTargetForTest(),
        :_exchange => ContextExchange(),
        (1, 2),
    ))
    interval_context = StatefulAlgorithms.context(init(interval_algo, Init(:_exchange; vars = (Var(:target, :seen),)); lifetime = Repeat(4)))
    interval_ref = view(interval_context, :seen)

    interval_context = StatefulAlgorithms._step!(interval_algo, interval_context)
    @test interval_context.target.seen == 1
    @test interval_ref[] == 0

    interval_context = StatefulAlgorithms._step!(interval_algo, interval_context)
    @test interval_context.target.seen == 2
    @test interval_ref[] == 2
end

@testset "ContextExchange supports aliases and type selectors" begin
    struct AliasedExchangeTargetForTest <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::AliasedExchangeTargetForTest, context)
        return (; value = 1.0)
    end

    function StatefulAlgorithms.step!(::AliasedExchangeTargetForTest, context)
        return (;)
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
    context = StatefulAlgorithms._step!(algo, context)

    @test context.target.value == 3.0
    @test ref[] == 3.0
end

@testset "InteractiveVar requires a ContextExchange" begin
    struct NoExchangeTargetForTest <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::NoExchangeTargetForTest, context)
        return (; value = 1.0)
    end

    algo = resolve(CompositeAlgorithm(:target => NoExchangeTargetForTest(), (1,)))
    context = initcontext(algo; lifetime = Repeat(1))

    @test_throws ErrorException view(context, :value)
end

@testset "ContextExchange timer skips reads and writes" begin
    struct TimedExchangeTargetForTest <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::TimedExchangeTargetForTest, context)
        return (; value = 1.0, seen = 0)
    end

    function StatefulAlgorithms.step!(::TimedExchangeTargetForTest, context)
        return (; seen = context.seen + 1)
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

    context = StatefulAlgorithms._step!(algo, context)
    @test value_ref[] == 1.0
    @test seen_ref[] == 1

    value_ref[] = 4
    context = StatefulAlgorithms._step!(algo, context)
    @test context.target.value == 1.0
    @test value_ref[] == 1.0
    @test seen_ref[] == 1
end

@testset "ContextExchange updates running process state" begin
    struct SlowInteractiveTargetForTest <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::SlowInteractiveTargetForTest, context)
        return (; value = 1, seen = 0)
    end

    function StatefulAlgorithms.step!(::SlowInteractiveTargetForTest, context)
        sleep(0.01)
        return (; seen = context.seen + 1)
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
