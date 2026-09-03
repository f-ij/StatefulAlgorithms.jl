using Test
using StatefulAlgorithms

StatefulAlgorithms.@StepAlgorithm function InspectionProducerForTest(
    @managed(history = Int[]);
    @inputs((; seed::Int = 1))
)
    push!(history, seed)
    return (; value = seed + 1)
end

StatefulAlgorithms.@StepAlgorithm function InspectionConsumerForTest(value)
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
    @test occursin("Init Requests", printed)
    @test occursin("Step Requests", printed)

    raw_plan = CompositeAlgorithm(
        InspectionProducerForTest(),
        InspectionConsumerForTest(),
        (1, 1),
        Route(InspectionProducerForTest => InspectionConsumerForTest, :value),
    )
    raw_plan_report = StatefulAlgorithms.inspect(raw_plan; steps = false)
    @test isnothing(getfield(raw_plan_report, :resolve_error))
    @test getfield(raw_plan_report, :resolved) isa StatefulAlgorithms.AbstractLoopAlgorithm

    nested_plan = Routine(InspectionProducerForTest(), (2,))
    nested_report = StatefulAlgorithms.inspect(CompositeAlgorithm(nested_plan, (1,)); steps = false)
    nested_node = only(getfield(getfield(nested_report, :execution_plan), :children))
    @test !occursin('\n', getfield(nested_node, :label))
    @test length(getfield(nested_node, :children)) == 1
    @test occursin("Repeat(2)", getfield(only(getfield(nested_node, :children)), :label))

    scheduled_report = StatefulAlgorithms.inspect(
        CompositeAlgorithm(InspectionProducerForTest(), InspectionConsumerForTest(), (2, 3));
        steps = false,
    )
    scheduled_children = getfield(getfield(scheduled_report, :execution_plan), :children)
    @test occursin("every 2", getfield(scheduled_children[1], :label))
    @test occursin("every 3", getfield(scheduled_children[2], :label))

    threaded_plan = ThreadedCompositeAlgorithm(InspectionProducerForTest(), (4,))
    threaded_report = StatefulAlgorithms.inspect(Routine(threaded_plan, (1,)); steps = false)
    threaded_node = only(getfield(getfield(threaded_report, :execution_plan), :children))
    @test occursin("ThreadedCompositeAlgorithm", getfield(threaded_node, :label))
    @test occursin("every 4", getfield(only(getfield(threaded_node, :children)), :label))

    conditional_plan = Routine(InspectionProducerForTest(), (Until(_ -> false),))
    conditional_report = StatefulAlgorithms.inspect(conditional_plan; steps = false)
    conditional_child = only(getfield(getfield(conditional_report, :execution_plan), :children))
    @test occursin("Until(condition)", getfield(conditional_child, :label))

    duplicate_report = StatefulAlgorithms.inspect(
        CompositeAlgorithm(
            Unique(InspectionProducerForTest()),
            Unique(InspectionProducerForTest()),
            (1, 1),
        );
        steps = false,
    )
    duplicate_labels = getfield.(getfield(getfield(duplicate_report, :execution_plan), :children), :label)
    @test length(unique(duplicate_labels)) == 2
    @test all(label -> occursin("InspectionProducerForTest_", label), duplicate_labels)

    runtime_input_comp = @CompositeAlgorithm begin
        @input temperature::AbstractFloat
        @input sweeps = 1
        InspectionConsumerForTest(value = temperature)
    end
    runtime_input_report = StatefulAlgorithms.inspect(runtime_input_comp; steps = false)
    runtime_inputs = getfield(runtime_input_report, :runtime_inputs)
    runtime_printed = sprint(show, runtime_input_report)

    @test getfield.(runtime_inputs, :name) == [:temperature, :sweeps]
    @test getfield.(runtime_inputs, :type_label) == ["AbstractFloat", "Any"]
    @test getfield.(runtime_inputs, :required) == [true, false]
    @test getfield.(runtime_inputs, :has_default) == [false, true]
    @test getfield(runtime_inputs[2], :default) == 1
    @test occursin("temperature::AbstractFloat (required)", runtime_printed)
    @test occursin("sweeps::Any (optional, default = 1)", runtime_printed)
end
