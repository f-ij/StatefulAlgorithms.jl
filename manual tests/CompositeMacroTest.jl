include("_env.jl")

@ProcessAlgorithm function MakeNoise(seed)
    println("Seed is: $(seed)")
    return (;noise = randn(seed))
end

@ProcessAlgorithm function PickRandomSeed(targetseed, @managed(seeds = [1234, 5678, 9012]))
    newseed = rand(seeds)
    println("Picked seed: $newseed")
    return (; targetseed = newseed)
end

function compfactory(seed)
    capture_noise = @CompositeAlgorithm begin
        @state changeable_seed = seed
        @alias noisemaker = MakeNoise

        noise = noisemaker(seed = changeable_seed)
        Logger(value = noise)
    end

    routinecomp = @Routine begin
        @context n = @repeat 2 capture_noise()
        PickRandomSeed(targetseed = n.changeable_seed)
    end

    return routinecomp
end

c = compfactory(42)
r = resolve(c)
p = InlineProcess(c, repeats = 5)
run(p);