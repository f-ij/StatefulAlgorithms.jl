using Test
using StatefulAlgorithms

isdefined(StatefulAlgorithms, :ContextAnalyzer) || Base.include(
    StatefulAlgorithms,
    joinpath(dirname(pathof(StatefulAlgorithms)), "ContextAnalyzer", "ContextAnalyzer.jl"),
)

StatefulAlgorithms.@ProcessAlgorithm function CaptureSeedForAnalyzerTest(
    @managed(history = Int[]);
    @inputs((; seed::Int, scale::Float64 = 1.0))
)
    push!(history, seed)
    return (; noise = seed * scale)
end

struct DirectContextReadForAnalyzerTest <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::DirectContextReadForAnalyzerTest, context::C) where {C <: StatefulAlgorithms.AbstractContext}
    upstream = context.noise
    mis = get(context, :missing_value, 99)
    indexed = context[:capture_seed]
    return (; upstream, mis, indexed)
end

@testset "Context Analyzer" begin
    comp = @CompositeAlgorithm begin
        @state seed = 4
        noise = CaptureSeedForAnalyzerTest(seed = seed)
        DirectContextReadForAnalyzerTest()
        Logger(value = noise)
    end

    analysis = StatefulAlgorithms.analyse_inits(comp)
    analysis_with_inputs = StatefulAlgorithms.analyse_inits(
        comp;
        inputs = (;
            CaptureSeedForAnalyzerTest_1 = (; seed = 4, scale = 2.0),
            DirectContextReadForAnalyzerTest_1 = (; noise = 8.0),
        ),
    )

    @test StatefulAlgorithms.requested_inputs(analysis) == Dict(
        :_state => [:seed],
        :CaptureSeedForAnalyzerTest_1 => [:seed],
        :DirectContextReadForAnalyzerTest_1 => [:noise, :missing_value, :capture_seed],
    )

    stored = StatefulAlgorithms.stored_inputs(analysis_with_inputs)
    @test stored[:_state] == (; seed = 4)
    @test stored[:CaptureSeedForAnalyzerTest_1] == (; seed = 4, scale = 2.0, history = Int[])
    @test stored[:DirectContextReadForAnalyzerTest_1] == (; noise = 8.0, upstream = 8.0, mis = 99, indexed = nothing)
    @test haskey(stored, :Logger_1)
    @test stored[:Logger_1] == (; log = Any[])

    memory = getfield(analysis, :memory)
    seeded_memory = getfield(analysis_with_inputs, :memory)
    @test length(memory.errors) == 1
    @test isempty(seeded_memory.errors)

    printed = sprint(io -> StatefulAlgorithms.printevents(io, analysis_with_inputs))
    @test occursin("ContextAnalyser events:", printed)
    @test occursin("DirectContextReadForAnalyzerTest_1", printed)
end
