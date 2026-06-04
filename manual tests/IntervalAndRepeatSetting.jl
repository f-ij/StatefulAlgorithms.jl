include("_env.jl")
using BenchmarkTools
mockcomp = @CompositeAlgorithm begin
    @state num = 0
    num = rand()
    num = sqrt(num)
    println(num)
end

square(x::N) where N = x^2

mockroutine = @Routine begin
    @state num = 0.0
    @state nums = Float64[]
    num = rand()
    num = @repeat 4 square(num)
    # println("Num: ", num)
    push!(nums, num)
end

rc = resolve(mockcomp)
rr = resolve(mockroutine)

pc = InlineProcess(mockcomp, repeats = 10)
pr = InlineProcess(mockroutine, repeats = 2)


c1 = run(pc);
c2 = run(pr);

e_c = context(pr)
e_c = StatefulAlgorithms.makecontext(pr)
e_c = StatefulAlgorithms._merge_into_globals(e_c, (; process=pr))

lifetime = StatefulAlgorithms.lifetime(pr)
mockroutine = resolve(mockroutine)

StatefulAlgorithms.loop(pr, mockroutine, e_c, lifetime)
@code_warntype StatefulAlgorithms.loop(pr, mockroutine, e_c, lifetime)
@code_warntype run(pr)

c = @benchmark StatefulAlgorithms.loop($pr, $mockroutine, e_c, $lifetime, StatefulAlgorithms.Generated()) setup = (e_c = StatefulAlgorithms._merge_into_globals(StatefulAlgorithms.makecontext(pr), (; process=pr)))
@benchmark run($pr)
    
function testloop(rr::R, context::C) where {R, C}
    for i in 1:2
        context = @inline StatefulAlgorithms.merge_into_subcontext_mutate(context, Val(:_state), (;num = rand()))
        for i in 1:4
            # context = @inline step!(rr[2], context, StatefulAlgorithms.Stable())
            context = @inline StatefulAlgorithms.merge_into_subcontext_mutate(context, Val(:_state), (;num = square(context._state.num)))
        end
        # context = @inline step!(rr[3], context, StatefulAlgorithms.Stable())
        @inline push!(context._state.nums, context._state.num)
    end
    return context 
end

e_c = StatefulAlgorithms.makecontext(pr)
cr = testloop(rr, e_c)


# @benchmark testloop($rr, c) setup = (c = StatefulAlgorithms._merge_into_globals(StatefulAlgorithms.makecontext(pr), (; process=pr)))
@benchmark testloop($rr, c) setup = (c = StatefulAlgorithms.makecontext(pr))

@code_warntype testloop(rr, e_c)
testloop(rr, e_c)

function mockroutine_mimic(num = 0.0, nums = Float64[])
    for i in 1:2
        num = rand()
        for i in 1:4
            num = @inline square(num)
        end
        @inline push!(nums, num)
    end
    return num, nums
end

num = 0.0
nums = Float64[]
@benchmark mockroutine_mimic($num, $nums)