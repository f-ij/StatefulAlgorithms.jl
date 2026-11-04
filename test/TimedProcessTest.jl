using Test
using StatefulAlgorithms

@StepAlgorithm function TimedCounter(@managed(count = 0, cleaned = false))
    @update count += 1
end

StatefulAlgorithms.cleanup(::TimedCounter, context) = (; cleaned = true)

@StepAlgorithm function TimedInputConsumer(delta, @managed(total = 0))
    @update total += delta
end

function wait_until(condition; timeout = 5.0)
    deadline = time() + timeout
    while !condition() && time() < deadline
        sleep(0.005)
    end
    return condition()
end

@testset "TimedProcess" begin
    @testset "Repeats end the run with cleanup" begin
        tp = TimedProcess(TimedCounter; interval = 0.01, repeats = 5)
        run(tp)
        @test wait_until(() -> !isrunning(tp))
        @test getcontext(tp)[TimedCounter].count == 5
        @test getcontext(tp)[TimedCounter].cleaned
        @test fetch(tp)[TimedCounter].count == 5
        @test isnothing(StatefulAlgorithms.getruntimecontext(tp))
        @test !ispaused(tp)
    end

    @testset "A lifetime condition ends the run" begin
        tp = TimedProcess(TimedCounter; interval = 0.01, lifetime = StatefulAlgorithms.Until(x -> x >= 3, Var(TimedCounter, :count)))
        run(tp)
        @test wait_until(() -> !isrunning(tp))
        @test getcontext(tp)[TimedCounter].count == 3

        # Already over before the first step: no step runs and no timer starts.
        done = TimedProcess(TimedCounter; interval = 0.01, lifetime = StatefulAlgorithms.Until(x -> x >= 0, Var(TimedCounter, :count)))
        run(done)
        @test !isrunning(done)
        @test getcontext(done)[TimedCounter].count == 0
        @test getcontext(done)[TimedCounter].cleaned
    end

    @testset "Pause keeps the runtime context, resume and close" begin
        algo = @CompositeAlgorithm begin
            @input delta::Int
            TimedInputConsumer(delta = delta)
        end
        tp = TimedProcess(algo; interval = 0.005)
        run(tp; delta = 2)
        @test_throws ErrorException run(tp)
        @test wait_until(() -> getlidx(tp) >= 4)
        pause(tp)
        @test ispaused(tp) && !isrunning(tp)

        paused_total = getcontext(tp)[TimedInputConsumer].total
        paused_lidx = getlidx(tp)
        @test paused_total == 2 * (paused_lidx - 1)
        @test StatefulAlgorithms.get_inputs(StatefulAlgorithms.getruntimecontext(tp)).delta == 2
        sleep(0.05)
        @test getlidx(tp) == paused_lidx   # no ticks while paused
        @test_throws ErrorException run(tp; delta = 3)

        run(tp)
        @test wait_until(() -> getlidx(tp) >= paused_lidx + 3)
        close(tp)
        @test !isrunning(tp) && !ispaused(tp)
        @test isnothing(StatefulAlgorithms.getruntimecontext(tp))
        @test getcontext(tp)[TimedInputConsumer].total > paused_total
        @test getlidx(tp) == 1
    end
end
