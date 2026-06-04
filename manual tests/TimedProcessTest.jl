include("_env.jl")
using Test
import StatefulAlgorithms as ps

# TimedProcess is not included in src/StatefulAlgorithms.jl yet.
if !isdefined(ps, :TimedProcess)
    Base.include(ps, joinpath(@__DIR__, "..", "src", "TimedProcess.jl"))
end

struct TimedDummy <: ps.ProcessAlgorithm end
ps.step!(::TimedDummy, context) = context

function build_dummy_timed_process()
    loop_algo = ps.CompositeAlgorithm((TimedDummy,), (1,))
    return ps.TimedProcess(loop_algo; interval = 0.01, context = (;))
end

@testset "TimedProcess manual API checks" begin
    tp = build_dummy_timed_process()

    @test tp.timer === nothing
    @test tp.paused == true

    @test_throws FieldError ps.run(tp)
    @test_throws MethodError ps.pause(tp)
    @test_throws MethodError close(tp)
end
