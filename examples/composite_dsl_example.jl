using StatefulAlgorithms

struct ExampleSourceAlgo <: StatefulAlgorithms.StepAlgorithm end
struct ExampleCombineAlgo <: StatefulAlgorithms.StepAlgorithm end
struct ExampleSinkAlgo <: StatefulAlgorithms.StepAlgorithm end

function StatefulAlgorithms.step!(::ExampleSourceAlgo, context)
    return (; produced = 2, passthrough = context.seed)
end

function StatefulAlgorithms.step!(::ExampleCombineAlgo, context)
    return (; combined = context.left + context.right)
end

function StatefulAlgorithms.step!(::ExampleSinkAlgo, context)
    return (; seen = context.value)
end

scaled_double_example(x; scale = 1) = scale * (2x)

state_only = @state begin
    a = 1
    b
end

println("standalone @state")
println(StatefulAlgorithms.init(state_only, (; b = 4)))
println()

n = 5
composite = @CompositeAlgorithm begin
    @state seed = 3
    @alias source = ExampleSourceAlgo

    produced, passthrough = source(seed = seed)
    doubled = @interval n scaled_double_example(produced; scale = 2)
    combined = @interval n ExampleCombineAlgo(left = passthrough, right = doubled)
    @interval n ExampleSinkAlgo(value = combined)
end

resolved_composite = resolve(composite)
process = Process(resolved_composite; repeats = 5)
run(process)
composite_context = fetch(process)

println("@CompositeAlgorithm with @state, @alias, plain function wrapping, and @interval")
println(composite_context)
println()

@CompositeAlgorithm :print begin
    @state seed = 3
    @alias source = ExampleSourceAlgo
    produced = source(seed = seed)
end
println()

named_state_composite = @CompositeAlgorithm begin
    @state mystate begin
        seed = 4
        offset = 7
    end

    @alias source = ExampleSourceAlgo
    produced, passthrough = source(seed = seed)
    value = +(produced, offset)
    ExampleSinkAlgo(value = value)
end

named_state_process = Process(resolve(named_state_composite); repeats = 1)
run(named_state_process)

println("@CompositeAlgorithm with named @state and transform route")
println(fetch(named_state_process))
println()

routine = @Routine begin
    @state seed = 2
    @alias source = ExampleSourceAlgo

    produced, passthrough = @repeat 3 source(seed = seed)
    doubled = scaled_double_example(produced; scale = 4)
    value = +(doubled, passthrough)
    ExampleSinkAlgo(value = value)
end

resolved_routine = resolve(routine)
routine_process = Process(resolved_routine; repeats = 1)
run(routine_process)

println("@Routine with @repeat on one statement")
println(fetch(routine_process))
println()

repeated_block = @CompositeAlgorithm begin
    @repeat 2 begin
        @state seed = 6
        @alias source = ExampleSourceAlgo

        produced, passthrough = source(seed = seed)
        carried = scaled_double_example(produced; scale = 3)
        value = scaled_double_example(carried; scale = passthrough)
        ExampleSinkAlgo(value = value)
    end
end

repeated_block_process = Process(resolve(repeated_block); repeats = 1)
run(repeated_block_process)

println("@repeat n begin ... end inside @CompositeAlgorithm")
println(fetch(repeated_block_process))
