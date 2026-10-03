include(joinpath(@__DIR__, "proto_normalize_defs.jl"))
a = Unique(Counter()); b = Unique(Counter())
norm = normalize_ids(a, b, Tally, (1, 1, 1))
plan = Base.invokelatest(CompositeAlgorithm, norm...)
short(x) = (s = string(x); length(s) > 110 ? s[1:110] * "..." : s)
rt(f, args...) = Base.return_types(f, typeof.(args))[1]

la0 = SA.LoopAlgorithm(plan)
println("LoopAlgorithm(plan):                     ", short(rt(SA.LoopAlgorithm, plan)))
setup = SA.setup_registry_and_keyed_algos
println("setup_registry_and_keyed_algos(la0):     ", short(rt(setup, la0)))
registry, keyed = setup(la0)
println("attach_registry_to_tree:                 ", short(rt(SA.attach_registry_to_tree, keyed, registry)))
keyed2 = SA.attach_registry_to_tree(keyed, registry)
println("resolve_plan_wiring:                     ", short(rt(SA.resolve_plan_wiring, keyed2, registry)))
println("resolve(la0) (the whole thing):          ", short(rt(resolve, la0)))
println("resolve(plan) (what the user calls):     ", short(rt(resolve, plan)))
# the pieces inside setup
states = SA.flat_states(la0)
println("flat_states(la0):                        ", short(rt(SA.flat_states, la0)))
println("add_algos_to_registry:                   ", short(rt(SA.add_algos_to_registry, SA.NameSpaceRegistry(), SA.getplan(la0), 1.0)))
