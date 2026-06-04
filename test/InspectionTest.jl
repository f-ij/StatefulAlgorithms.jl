using Test
using StatefulAlgorithms

StatefulAlgorithms.@ProcessAlgorithm function InspectionProducerForTest(
    @managed(history = Int[]);
    @inputs((; seed::Int = 1))
)
    push!(history, seed)
    return (; value = seed + 1)
end

StatefulAlgorithms.@ProcessAlgorithm function InspectionConsumerForTest(value)
    return (; doubled = 2value)
end

@testset "Inspection" begin
    comp = @CompositeAlgorithm begin
        @state seed = 4
        value = InspectionProducerForTest(seed = seed)
        InspectionConsumerForTest(value = value)
    end

    report = StatefulAlgorithms.inspect(comp)
    printed = sprint(show, report)

    @test report isa StatefulAlgorithms.InspectionReport
    @test isnothing(getfield(report, :resolve_error))
    @test !isempty(getfield(report, :registry_entries))
    @test !isempty(getfield(report, :state_entries))
    @test !isempty(getfield(report, :algorithm_entries))
    @test occursin("InspectionReport", printed)
    @test occursin("Runtime Inputs", printed)
    @test occursin("<no declared metadata>", printed)
    @test occursin("InspectionProducerForTest", printed)
    @test occursin("Init Reads", printed)
end
