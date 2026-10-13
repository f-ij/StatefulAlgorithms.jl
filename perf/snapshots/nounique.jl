# A plan without Unique handles: does a caller know resolve's result type, and what do the first and repeated calls cost?
using StatefulAlgorithms, Statistics
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); @update x = x + 1.0; return x; end
@StepAlgorithm function Adder(a, b, @managed(sum = 0.0)); @update sum = a + b; return sum; end
@StepAlgorithm function Reader(x, @managed(seen = 0.0)); @update seen = x; return seen; end
inner = @Routine begin
    @alias c = Counter
    x = c()
    Reader(x = x)
end
comp = @CompositeAlgorithm begin
    @alias total = Adder
    @alias echo = Reader
    x = Counter()
    total(a = x, b = x)
    @context r = @interval 3 inner()
    echo()
    @route total.sum => echo.x
end
Base.cumulative_compile_timing(true)
c0 = Base.cumulative_compile_time_ns()[1]; t0 = time_ns(); resolve(comp); t1 = time_ns(); c1 = Base.cumulative_compile_time_ns()[1]
times = Float64[]
for _ in 1:200
    s = time_ns(); resolve(comp); push!(times, (time_ns() - s) / 1e3)
end
caller(la) = resolve(la)
known = isconcretetype(Base.return_types(caller, (typeof(comp),))[1])
println("NOUNIQUE\t", ARGS[1], "\t", known, "\t", round((c1 - c0) / 1e3; digits = 1), "\t", round((t1 - t0) / 1e3; digits = 1), "\t", round(median(times); digits = 2))
