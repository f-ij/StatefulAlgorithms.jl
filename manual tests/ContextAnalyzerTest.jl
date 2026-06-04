include("_env.jl")

Base.include(StatefulAlgorithms, joinpath(dirname(pathof(StatefulAlgorithms)), "ContextAnalyzer", "ContextAnalyzer.jl"))

StatefulAlgorithms.@ProcessAlgorithm function CaptureSeed(
    @managed(history = Int[]);
    @inputs((; seed::Int, scale::Float64 = 1.0))
)
    push!(history, seed)
    return (; noise = seed * scale)
end

struct DirectContextRead <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::DirectContextRead, context::C) where {C <: StatefulAlgorithms.AbstractContext}
    upstream = context.noise
    mis = get(context, :missing_value, 99)
    indexed = context[:capture_seed]
    return (; upstream, mis, indexed)
end

comp = @CompositeAlgorithm begin
    @state seed = 4
    noise = CaptureSeed(seed = seed)
    DirectContextRead()
    Logger(value = noise)
end

analysis = StatefulAlgorithms.analyse_inits(comp)
analysis_with_inputs = StatefulAlgorithms.analyse_inits(
    comp;
    inputs = (;
        CaptureSeed_1 = (; seed = 4, scale = 2.0),
        DirectContextRead_1 = (; noise = 8.0),
    ),
)
step_analysis = StatefulAlgorithms.analyse_steps(
    comp;
    inputs = (;
        CaptureSeed_1 = (; seed = 4, scale = 2.0),
        DirectContextRead_1 = (; noise = 8.0),
    ),
)

println("Requested inputs by view:")
for view_key in sort!(collect(keys(StatefulAlgorithms.requested_inputs(analysis))); by = string)
    println("  ", view_key, " => ", StatefulAlgorithms.requested_inputs(analysis)[view_key])
end

println()
println(analysis)

println()
println("Stored inputs after seeded analysis:")
for view_key in sort!(collect(keys(StatefulAlgorithms.stored_inputs(analysis_with_inputs))); by = string)
    println("  ", view_key, " => ", StatefulAlgorithms.stored_inputs(analysis_with_inputs)[view_key])
end

println()
StatefulAlgorithms.printevents(analysis_with_inputs)

println()
println("Stored inputs after seeded step analysis:")
for view_key in sort!(collect(keys(StatefulAlgorithms.stored_inputs(step_analysis))); by = string)
    println("  ", view_key, " => ", StatefulAlgorithms.stored_inputs(step_analysis)[view_key])
end
