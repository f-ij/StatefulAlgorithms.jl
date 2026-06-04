using Test
using StatefulAlgorithms

struct LifecycleInitA <: StatefulAlgorithms.ProcessAlgorithm end
struct LifecycleInitB <: StatefulAlgorithms.ProcessAlgorithm end
mutable struct RuntimeShapeChanger <: StatefulAlgorithms.ProcessAlgorithm
    count::Int
end
struct PauseRuntimeInputConsumer <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::LifecycleInitA, context)
    return (; x = Ref(get(context, :x, 0)), z = get(context, :z, 0))
end

function StatefulAlgorithms.init(::LifecycleInitB, context)
    return (; y = Ref(get(context, :y, 0)))
end

function StatefulAlgorithms.step!(::LifecycleInitA, context)
    context.x[] += 1
    return (;)
end

function StatefulAlgorithms.step!(::LifecycleInitB, context)
    context.y[] += 1
    return (;)
end

function StatefulAlgorithms.step!(algo::RuntimeShapeChanger, context)
    algo.count += 1
    return algo.count == 1 ? (; added = 1) : (; added = 1, extra = 1)
end

StatefulAlgorithms.init(::PauseRuntimeInputConsumer, context) = (; total = 0)

function StatefulAlgorithms.step!(::PauseRuntimeInputConsumer, context)
    sleep(0.005)
    return (; total = context.total + context.delta)
end

runtime_inputs_lifecycle_value(seed, temp, scale; bias = 0) = seed + temp * scale + bias
runtime_shape_context(ctx) = getproperty(StatefulAlgorithms.get_subcontexts(ctx), :RuntimeShapeChanger_1)
runtime_input_bucket(ctx) = getproperty(StatefulAlgorithms.get_subcontexts(ctx), :_input)

@testset "Runtime inputs and LoopAlgorithm lifecycle" begin
    @test Input === Init
    @test Init(LifecycleInitA; x = 1).vars == (; x = 1)
    @test Init(; x = 1).vars == (; x = 1)
    @test Input(LifecycleInitA, :x => 2).vars == (; x = 2)
    @test !StatefulAlgorithms.isresolved(Init(LifecycleInitA; x = 1))
    @test !StatefulAlgorithms.isresolved(typeof(Init(LifecycleInitA; x = 1)))
    @test !StatefulAlgorithms.isresolved(Init(; x = 1))
    @test !StatefulAlgorithms.isresolved(typeof(Init(; x = 1)))
    @test StatefulAlgorithms.isalltargets(Init(; x = 1))
    @test StatefulAlgorithms.isalltargets(typeof(Init(; x = 1)))
    @test !StatefulAlgorithms.isalltargets(Init(LifecycleInitA; x = 1))
    @test !StatefulAlgorithms.isalltargets(Override(LifecycleInitA; x = 1))
    @test StatefulAlgorithms.isresolved(Init(:LifecycleInitA_1; x = 1))
    @test StatefulAlgorithms.isresolved(typeof(Init(:LifecycleInitA_1; x = 1)))

    la = CompositeAlgorithm(LifecycleInitA, LifecycleInitB, (1, 1))
    initialized = init(la, Init(LifecycleInitA; x = 1), Init(LifecycleInitB; y = 2))
    replayed = init(initialized)
    overridden = init(replayed, Init(LifecycleInitA; x = 5))

    @test StatefulAlgorithms.context(replayed)[LifecycleInitA].x[] == 1
    @test StatefulAlgorithms.context(replayed)[LifecycleInitB].y[] == 2
    @test StatefulAlgorithms.context(overridden)[LifecycleInitA].x[] == 5
    @test StatefulAlgorithms.context(overridden)[LifecycleInitB].y[] == 2

    general_init = init(la, Init(; x = 3, y = 4, z = 5))
    @test StatefulAlgorithms.context(general_init)[LifecycleInitA].x[] == 3
    @test StatefulAlgorithms.context(general_init)[LifecycleInitA].z == 5
    @test StatefulAlgorithms.context(general_init)[LifecycleInitB].y[] == 4

    targeted_after_general = init(la, Init(; x = 3, y = 4), Init(LifecycleInitA; x = 8))
    @test StatefulAlgorithms.context(targeted_after_general)[LifecycleInitA].x[] == 8
    @test StatefulAlgorithms.context(targeted_after_general)[LifecycleInitB].y[] == 4

    b_ref = StatefulAlgorithms.context(overridden)[LifecycleInitB].y
    partial = partialinit(overridden, Init(LifecycleInitA; x = 9, z = 4))

    @test StatefulAlgorithms.context(partial)[LifecycleInitA].x[] == 9
    @test StatefulAlgorithms.context(partial)[LifecycleInitA].z == 4
    @test StatefulAlgorithms.context(partial)[LifecycleInitB].y === b_ref

    resolved_la = resolve(la)
    resolved_target = getkey(only(findall(LifecycleInitA, StatefulAlgorithms.getregistry(resolved_la))))
    resolved_input = only(StatefulAlgorithms.resolve(StatefulAlgorithms.getregistry(resolved_la), Init(resolved_target; x = 7)))
    @test StatefulAlgorithms.get_ref(resolved_input) === nothing
    @test StatefulAlgorithms.isresolved(resolved_input)
    @test StatefulAlgorithms.isresolved(typeof(resolved_input))
    resolved_general_inputs = StatefulAlgorithms.resolve(StatefulAlgorithms.getregistry(resolved_la), Init(; x = 11))
    @test length(resolved_general_inputs) == length(keys(StatefulAlgorithms.getregistry(resolved_la)))
    @test all(StatefulAlgorithms.isresolved, resolved_general_inputs)
    initialized_by_symbol = init(resolved_la, Init(resolved_target; x = 7))
    @test StatefulAlgorithms.context(initialized_by_symbol)[LifecycleInitA].x[] == 7

    runtime_algo = @CompositeAlgorithm begin
        @state seed = 1
        @input temp::AbstractFloat
        @input scale
        @input bias = 2.0
        value = runtime_inputs_lifecycle_value(seed, temp, scale; bias = bias)
    end
    initialized_runtime = init(resolve(runtime_algo))

    @test_throws ErrorException run(initialized_runtime)
    @test_throws ErrorException run(initialized_runtime; temp = 1.0, scale = 2, extra = 1)
    @test_throws ErrorException run(initialized_runtime; temp = 1, scale = 2)

    runtime_result = run(initialized_runtime; temp = 1.5, scale = 2)
    runtime_context = StatefulAlgorithms.context(runtime_result)
    @test isempty(runtime_context[:FuncWrapper_1])
    @test !haskey(StatefulAlgorithms.getglobals(runtime_context), :value)
    @test isempty(StatefulAlgorithms.getruntimeinput(runtime_context))
    @test isempty(runtime_input_bucket(runtime_context))
    @test !haskey(StatefulAlgorithms.getglobals(runtime_context), :process)

    for entry in (runtime_algo, resolve(runtime_algo), initialized_runtime)
        process = Process(entry; repeats = 1)
        run(process; temp = 2.0, scale = 3)
        wait(process)
        @test StatefulAlgorithms._has_typed_runtime_context(process)
        @test isnothing(process.runtime_context)
        fetched_context = fetch(process)
        @test !haskey(StatefulAlgorithms.getglobals(fetched_context), :value)
        @test isempty(StatefulAlgorithms.context(process)[:FuncWrapper_1])
        @test !haskey(StatefulAlgorithms.getglobals(StatefulAlgorithms.context(process)), :value)
        @test isempty(StatefulAlgorithms.getruntimeinput(StatefulAlgorithms.context(process)))
        @test isempty(runtime_input_bucket(StatefulAlgorithms.context(process)))
        @test !haskey(StatefulAlgorithms.getglobals(StatefulAlgorithms.context(process)), :process)
        close(process)
    end

    inline_worker = Process(runtime_algo; repeats = 1)
    StatefulAlgorithms.runprocessinline!(inline_worker; temp = 2.0, scale = 3)
    @test StatefulAlgorithms._has_typed_runtime_context(inline_worker)
    @test isnothing(inline_worker.runtime_context)
    @test !haskey(StatefulAlgorithms.getglobals(fetch(inline_worker)), :value)
    @test isempty(StatefulAlgorithms.context(inline_worker)[:FuncWrapper_1])
    @test !haskey(StatefulAlgorithms.getglobals(StatefulAlgorithms.context(inline_worker)), :value)
    @test isempty(StatefulAlgorithms.getruntimeinput(StatefulAlgorithms.context(inline_worker)))
    @test isempty(runtime_input_bucket(StatefulAlgorithms.context(inline_worker)))
    @test !haskey(StatefulAlgorithms.getglobals(StatefulAlgorithms.context(inline_worker)), :process)
    close(inline_worker)

    per_run_repeats_process = Process(runtime_algo)
    run(per_run_repeats_process; repeats = 1, temp = 2.0, scale = 3)
    wait(per_run_repeats_process)
    @test !haskey(StatefulAlgorithms.getglobals(fetch(per_run_repeats_process)), :value)
    @test StatefulAlgorithms.lifetime(per_run_repeats_process) == Repeat(1)
    close(per_run_repeats_process)

    per_run_lifetime_process = Process(runtime_algo)
    run(per_run_lifetime_process; lifetime = Repeat(1), temp = 1.5, scale = 2)
    wait(per_run_lifetime_process)
    @test !haskey(StatefulAlgorithms.getglobals(fetch(per_run_lifetime_process)), :value)
    close(per_run_lifetime_process)

    positional_specs_process = Process(runtime_algo; repeats = 1)
    @test_throws ErrorException run(positional_specs_process, nothing, Input(; seed = 2); temp = 1.0, scale = 2)

    inline_process = InlineProcess(runtime_algo; repeats = 1)
    inline_result = run(inline_process; temp = 2.0, scale = 3)
    @test !haskey(StatefulAlgorithms.getglobals(inline_result), :value)
    @test isempty(StatefulAlgorithms.context(inline_process)[:FuncWrapper_1])
    @test !haskey(StatefulAlgorithms.getglobals(StatefulAlgorithms.context(inline_process)), :value)
    @test isempty(StatefulAlgorithms.getruntimeinput(StatefulAlgorithms.context(inline_process)))
    @test isempty(getproperty(StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.context(inline_process)), :_input))

    inline_nogen_result = StatefulAlgorithms.run_nogen(inline_process; temp = 1.5, scale = 2)
    @test !haskey(StatefulAlgorithms.getglobals(inline_nogen_result), :value)
    @test isempty(StatefulAlgorithms.getruntimeinput(StatefulAlgorithms.context(inline_process)))
    @test isempty(getproperty(StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.context(inline_process)), :_input))
    @test_throws ErrorException run(inline_process)
    @test_throws ErrorException run(inline_process; temp = 1, scale = 2)
    @test_throws ErrorException run(inline_process, Input(; seed = 2); temp = 1.0, scale = 2)

    shape_result = run(init(CompositeAlgorithm(RuntimeShapeChanger(0))); lifetime = Repeat(0))
    @test isempty(runtime_shape_context(StatefulAlgorithms.context(shape_result)))
    widened_shape_result = run(init(CompositeAlgorithm(RuntimeShapeChanger(0))); lifetime = Repeat(2))
    @test isempty(runtime_shape_context(StatefulAlgorithms.context(widened_shape_result)))

    pause_algo = @CompositeAlgorithm begin
        @input delta::Int
        PauseRuntimeInputConsumer(delta = delta)
    end
    process = Process(pause_algo; repeat = Inf)
    run(process; delta = 2)

    deadline = time() + 2.0
    while loopint(process) < 4 && time() < deadline
        sleep(0.005)
    end
    pause(process)
    wait(process)

    paused_context = context(process)
    paused_total = paused_context[PauseRuntimeInputConsumer].total
    @test paused_total > 0
    @test haskey(StatefulAlgorithms.get_subcontexts(paused_context), :_input)
    @test_throws ErrorException run(process; delta = 3)

    run(process)
    deadline = time() + 2.0
    while loopint(process) < 7 && time() < deadline
        sleep(0.005)
    end
    pause(process)
    wait(process)

    @test context(process)[PauseRuntimeInputConsumer].total > paused_total
    close(process)
    @test StatefulAlgorithms._has_typed_runtime_context(process)
    @test isnothing(process.runtime_context)
    @test isempty(StatefulAlgorithms.getruntimeinput(context(process)))
    @test isempty(runtime_input_bucket(context(process)))
end
