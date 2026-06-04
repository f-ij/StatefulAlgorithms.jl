using StatefulAlgorithms

StatefulAlgorithms.@ProcessAlgorithm function InspectSource(
    @managed(counter = 0);
    @inputs((; seed::Int = 1))
)
    value = seed + counter
    return (; counter = counter + 1, value)
end

StatefulAlgorithms.@ProcessAlgorithm function InspectScale(value, factor)
    return (; scaled = factor * value)
end

StatefulAlgorithms.@ProcessAlgorithm function InspectSink(
    value,
    @managed(log = Int[])
)
    push!(log, value)
    return (; last = value)
end

StatefulAlgorithms.@ProcessAlgorithm function InspectOscillator(
    @managed(dt),
    @managed(state = 1.0),
    @managed(velocity = 0.0),
    @managed(trajectory = Float64[]);
    @inputs((; dt = 0.1))
)
    velocity = velocity - dt * state
    state = state + dt * velocity
    push!(trajectory, state)
    return (; state, velocity)
end

StatefulAlgorithms.@ProcessAlgorithm function InspectDamper(
    state,
    velocity,
    trajectory,
    @managed(damp = 0.05)
)
    velocity = velocity * (1 - damp)
    push!(trajectory, state)
    return (; velocity)
end

function print_report(title, algo; inputs = (;), steps = false)
    println()
    println("=" ^ 80)
    println(title)
    println("=" ^ 80)
    println(inspect(algo; inputs, steps))
end

# 1. Flat DSL composition.
#
# This is the baseline case: one DSL-owned state field feeds a source, the source
# feeds a transform step, and the transformed value feeds a sink.
flat_pipeline = @CompositeAlgorithm begin
    @state seed = 10
    @state factor = 3

    value = InspectSource(seed = seed)
    scaled = InspectScale(value, factor)
    InspectSink(value = scaled)
end

print_report("flat pipeline with DSL state and routed values", flat_pipeline)

# 2. Explicit context sharing.
#
# The oscillator and damper share the full oscillator context. This is the kind
# of composition where inspection should make ownership and sharing visible.
oscillator = InspectOscillator()
damper = InspectDamper()

shared_context_pipeline = CompositeAlgorithm(
    oscillator,
    damper,
    (1, 1),
    Share(oscillator, damper),
)

print_report(
    "explicit Share between two process algorithms",
    shared_context_pipeline;
    inputs = (; InspectOscillator_1 = (; dt = 0.05)),
)

# 3. Nested routine used inside an outer composite.
#
# This stresses transitive composition. The report flattens the registered
# algorithms while preserving the routes and reads that inspection can infer.
inner_relaxation = @Routine begin
    @state seed = 3
    @state factor = 2

    value = @repeat 2 InspectSource(seed = seed)
    scaled = InspectScale(value, factor)
    InspectSink(value = scaled)
end

outer_composition = @CompositeAlgorithm begin
    @state outer_seed = 7

    outer_value = InspectSource(seed = outer_seed)
    @interval 2 inner_relaxation()
    InspectSink(value = outer_value)
end

print_report("outer composite containing a reusable inner routine", outer_composition)

# To also include the best-effort step pass, call:
# println(inspect(flat_pipeline; steps = true))
