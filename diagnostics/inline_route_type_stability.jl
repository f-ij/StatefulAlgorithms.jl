include("inline_route_heavy_breakdown.jl")

using Test
using StatefulAlgorithms

const INLINE_ROUTE_TYPE_STABILITY_STEPS = parse(Int, get(ENV, "INLINE_ROUTE_TYPE_STABILITY_STEPS", "10"))

"""Return the static inference result for one callable and argument tuple."""
function inline_route_return_type(f::F, args::Type{A}) where {F, A<:Tuple}
    return Core.Compiler.return_type(f, args)
end

"""Check that each routed child step in the resolved plan is inferred."""
function inline_route_check_child_steps(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    algo = StatefulAlgorithms.getalgo(process)
    plan = StatefulAlgorithms.getplan(algo)
    root_wiring = StatefulAlgorithms._root_wiring_view(algo, plan)
    namespace_type = typeof(plan).parameters[3]
    algos = StatefulAlgorithms.getalgos(plan)
    context = StatefulAlgorithms.context(process)
    lifetime = StatefulAlgorithms.lifetime(process)
    runtimecontext = StatefulAlgorithms._merge_into_globals(StatefulAlgorithms._empty_context(), (; process, lifetime))

    # Step children in resolved plan order so each routed input is available
    # exactly as it is during the real composite loop.
    for index in eachindex(algos)
        child = getfield(algos, index)
        child_wiring = StatefulAlgorithms.child_wiring_view(root_wiring, Val(index))
        child_namespace = fieldtype(namespace_type, index)()
        context, runtimecontext = @inferred StatefulAlgorithms._step!(
            child,
            context,
            runtimecontext,
            child_wiring,
            child_namespace,
            process,
            lifetime,
        )
    end

    return context
end

"""Run type-inference checks for the inline route-heavy benchmark."""
function run_inline_route_type_stability_diagnostic(; steps::I = INLINE_ROUTE_TYPE_STABILITY_STEPS) where {I<:Integer}
    process = inline_route_process(steps)
    reset!(process)

    public_run_type = inline_route_return_type(run, Tuple{typeof(process)})
    direct_loop_type = inline_route_return_type(inline_route_direct_loop, Tuple{typeof(process)})
    generated_processloop_type = inline_route_return_type(inline_route_generated_processloop, Tuple{typeof(process)})
    direct_plan_type = inline_route_return_type(inline_route_direct_plan_loop, Tuple{typeof(process)})

    @testset "inline route-heavy type stability" begin
        reset!(process)
        public_run_result = @inferred run(process)
        @test public_run_result isa StatefulAlgorithms.ProcessContext
        @test public_run_type <: StatefulAlgorithms.ProcessContext

        reset!(process)
        direct_loop_result = @inferred inline_route_direct_loop(process)
        @test direct_loop_result isa StatefulAlgorithms.ProcessContext
        @test direct_loop_type <: StatefulAlgorithms.ProcessContext

        reset!(process)
        generated_processloop_result = @inferred inline_route_generated_processloop(process)
        @test generated_processloop_result isa StatefulAlgorithms.ProcessContext
        @test generated_processloop_type <: StatefulAlgorithms.ProcessContext

        reset!(process)
        direct_plan_result = @inferred inline_route_direct_plan_loop(process)
        @test direct_plan_result isa StatefulAlgorithms.ProcessContext
        @test direct_plan_type <: StatefulAlgorithms.ProcessContext

        reset!(process)
        child_result = inline_route_check_child_steps(process)
        @test child_result isa StatefulAlgorithms.ProcessContext
    end

    println("inline_route_type_stability_steps=", steps)
    println("public_run_return_type=", public_run_type)
    println("direct_loop_return_type=", direct_loop_type)
    println("generated_processloop_return_type=", generated_processloop_type)
    println("direct_plan_return_type=", direct_plan_type)
    println("public_run_inferred=", public_run_type !== Any)
    println("direct_loop_inferred=", direct_loop_type !== Any)
    println("generated_processloop_inferred=", generated_processloop_type !== Any)
    println("direct_plan_inferred=", direct_plan_type !== Any)

    return (; public_run_type, direct_loop_type, generated_processloop_type, direct_plan_type)
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_inline_route_type_stability_diagnostic()
end
