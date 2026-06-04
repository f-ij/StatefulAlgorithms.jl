include("_env.jl")

function IntegrateAndLog(type = Float64, loginterval = 1)
    integrator = Integrator(type)
    logger = Logger(type, name = :integrate_and_log)
    c = CompositeAlgorithm(integrator, logger, (1, loginterval), Route(integrator => logger, :total => :value))
    pack = package(c)
end

IntegrateAndLogger = IntegrateAndLog()

@ProcessAlgorithm function generate_values()
    val = rand()
    println("Generated: ", val)
    return (;output = val)
end

function StatefulAlgorithms.init(::generate_values, context)
    println("Initializing generate_values")
    (;output = 0.0)
end

comp = CompositeAlgorithm(generate_values, IntegrateAndLogger, (1,1), Route(generate_values => IntegrateAndLogger, :output => :Δvalue, transform = x -> begin println("x: ", x); x end))

p = StatefulAlgorithms.Process(comp, lifetime = 10, Input(IntegrateAndLogger, initialvalue = 101f0))
run(p)
