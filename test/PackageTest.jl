using Test
using StatefulAlgorithms

struct PackFib <: StatefulAlgorithms.ProcessAlgorithm end
struct PackLuc <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.step!(::PackFib, context)
    fiblist = context.fiblist
    push!(fiblist, fiblist[end] + fiblist[end - 1])
    return (;)
end

struct NewPackSource <: StatefulAlgorithms.ProcessAlgorithm end
struct NewPackTarget <: StatefulAlgorithms.ProcessAlgorithm end
struct NewPackOuterSource <: StatefulAlgorithms.ProcessAlgorithm end
struct NewPackNeedsRoute <: StatefulAlgorithms.ProcessAlgorithm end
struct NewPackCounter <: StatefulAlgorithms.ProcessAlgorithm end

StatefulAlgorithms.init(::NewPackSource, context) = (; value = 0)
StatefulAlgorithms.init(::NewPackOuterSource, context) = (; delta = 0)

function StatefulAlgorithms.step!(::NewPackSource, context)
    return (; value = context.value + 1)
end

function StatefulAlgorithms.step!(::NewPackOuterSource, context)
    return (; delta = context.delta + 1)
end

function StatefulAlgorithms.init(::NewPackTarget, context)
    log = Int[]
    processsizehint!(log, context)
    return (; log, expected_calls = StatefulAlgorithms.num_calls(context))
end

StatefulAlgorithms.init(::NewPackCounter, context) = (; expected_calls = StatefulAlgorithms.num_calls(context))
StatefulAlgorithms.step!(::NewPackCounter, context) = (;)

function StatefulAlgorithms.step!(::NewPackTarget, context)
    push!(context.log, context.input)
    return (;)
end

StatefulAlgorithms.init(::NewPackNeedsRoute, context) = (; seen = 0)
StatefulAlgorithms.step!(::NewPackNeedsRoute, context) = (; seen = context.delta)

@testset "Package runs as a ProcessAlgorithm" begin
    comp = CompositeAlgorithm(
        NewPackSource,
        NewPackTarget,
        (1, 2),
        Route(NewPackSource => NewPackTarget, :value => :input),
    )
    pkg = Package(comp, "NewPack")

    @test pkg isa ProcessAlgorithm
    @test !(pkg isa StatefulAlgorithms.AbstractIdentifiableAlgo)
    @test StatefulAlgorithms.getname(pkg) == :NewPack
    @test StatefulAlgorithms.intervals(pkg) == StatefulAlgorithms.intervals(comp)
    @test all(child -> child isa SubPackage, StatefulAlgorithms.getalgos(pkg))
    @test all(child -> !haskey(child), StatefulAlgorithms.getalgos(pkg))
    @test map(child -> StatefulAlgorithms.getalgo(child), StatefulAlgorithms.getalgos(pkg)) == map(StatefulAlgorithms.getalgo, StatefulAlgorithms.getalgos(comp))
    @test StatefulAlgorithms.algo_to_subcontext_names(StatefulAlgorithms.getvaraliases(StatefulAlgorithms.getalgo(pkg, 2)), :input) == :value
    reg = StatefulAlgorithms.NameSpaceRegistry()
    reg, registered_pkg = StatefulAlgorithms.add(reg, pkg, 1.0)
    @test StatefulAlgorithms.getkey(registered_pkg) == :NewPack_1
    @test StatefulAlgorithms.algoname(registered_pkg) == :NewPack

    p = Process(pkg; repeats = 6)
    run(p)
    wait(p)
    ctx = fetch(p)

    @test ctx[pkg].value == 6
    @test ctx[pkg].log == [2, 4, 6]
    @test ctx[pkg].expected_calls == 3
    @test StatefulAlgorithms.inc(pkg) == 1

    nested_pkg = Package(comp)
    outer = CompositeAlgorithm(nested_pkg, (2,))
    nested_process = Process(outer; repeats = 8)
    run(nested_process)
    wait(nested_process)
    nested_ctx = fetch(nested_process)

    @test nested_ctx[nested_pkg].log == [2, 4]
    @test nested_ctx[nested_pkg].expected_calls == 2

    repeated = Package((NewPackCounter, NewPackCounter), (2, 3))
    repeated_process = Process(repeated; repeats = 12)
    run(repeated_process)
    wait(repeated_process)
    repeated_ctx = fetch(repeated_process)

    @test repeated_ctx[repeated].expected_calls == 10

    unique_pkg = StatefulAlgorithms.Unique(Package(comp, "UniquePack"))
    unique_process = Process(unique_pkg; repeats = 6)
    run(unique_process)
    wait(unique_process)
    unique_ctx = fetch(unique_process)

    @test unique_ctx[unique_pkg].log == [2, 4, 6]
    @test unique_ctx[unique_pkg].expected_calls == 3

    routed_into_package = Package((NewPackNeedsRoute,), (1,))
    outer_routed = CompositeAlgorithm(
        NewPackOuterSource,
        routed_into_package,
        (1, 1),
        Route(NewPackOuterSource => routed_into_package, :delta),
    )
    routed_process = Process(outer_routed; repeats = 4)
    run(routed_process)
    wait(routed_process)
    routed_ctx = fetch(routed_process)

    @test routed_ctx[routed_into_package].seen == 4
end

function StatefulAlgorithms.init(::PackFib, context)
    fiblist = Int[0, 1]
    processsizehint!(fiblist, context)
    return (;fiblist)
end

function StatefulAlgorithms.step!(::PackLuc, context)
    luclist = context.luclist
    push!(luclist, luclist[end] + luclist[end - 1])
    return (;)
end

function StatefulAlgorithms.init(::PackLuc, context)
    luclist = Int[2, 1]
    processsizehint!(luclist, context)
    return (;luclist)
end

@testset "Registry findall by algorithm type" begin
    fib1 = StatefulAlgorithms.Unique(PackFib)
    fib2 = StatefulAlgorithms.Unique(PackFib)
    comp = resolve(CompositeAlgorithm(fib1, fib2, PackLuc, (1, 1, 1)))
    reg = StatefulAlgorithms.getregistry(comp)

    fib_matches = findall(PackFib, reg)
    luc_matches = findall(PackLuc, reg)

    @test length(fib_matches) == 2
    @test all(match -> StatefulAlgorithms.getalgo(match) isa PackFib, fib_matches)
    @test length(luc_matches) == 1
    @test StatefulAlgorithms.getalgo(only(luc_matches)) isa PackLuc
end

@testset "Package runs and benchmarks" begin
    n = 1_000
    @show n
    fibluc = CompositeAlgorithm( PackFib, PackLuc , (1, 1))
    pack = Package(fibluc, "FLPack")

    @test !haskey(pack)
    @test !StatefulAlgorithms.hasautokey(pack)
    keyed_pack = StatefulAlgorithms.Autokey(pack, 1)
    @test haskey(keyed_pack)
    @test StatefulAlgorithms.hasautokey(keyed_pack)

    reg = StatefulAlgorithms.NameSpaceRegistry()
    reg, registered_pack = StatefulAlgorithms.add(reg, pack, 1.0)
    reg, reregistered_pack = StatefulAlgorithms.add(reg, pack, 1.0)
    @test StatefulAlgorithms.getkey(registered_pack) == :FLPack_1
    @test StatefulAlgorithms.getkey(reregistered_pack) == :FLPack_1

    p = Process(pack; repeats = n)
    run(p)
    wait(p)
    ctx = fetch(p)

    @test length(ctx[pack].fiblist) == n + 2
    @test length(ctx[pack].luclist) == n + 2

    routed_fibluc = CompositeAlgorithm(
        PackFib,
        PackLuc,
        (1, 1),
        Route(PackFib => PackLuc, :fiblist => :source_fib),
    )
    routed_pack = Package(routed_fibluc, "RoutedFLPack")
    routed_aliases = StatefulAlgorithms.getvaraliases(StatefulAlgorithms.getalgo(routed_pack, 2))
    @test StatefulAlgorithms.algo_to_subcontext_names(routed_aliases, :source_fib) == :fiblist

    bench = benchmark(pack, n, 1)
    @test bench > 0

    # Test routes to package
     # Route functions test
    struct PackLogger{T} <: ProcessAlgorithm end
    PackLogger(name::Symbol) = PackLogger{name}()

    function StatefulAlgorithms.init(::PackLogger{T}, _input) where {T}
        log = Vector{Any}()
        processsizehint!(log, _input)
        return (;log)
    end
    function StatefulAlgorithms.step!(::PackLogger{T}, context) where {T}
        (;log, targetnum) = context
        push!(log, targetnum)
        return (;)
    end

    Logger1 = PackLogger(:fibidiboo)
    Logging = CompositeAlgorithm( pack, Logger1, (1, 100), 
        Route(pack => Logger1, :fiblist => :targetnum, transform = x -> x[end]))
    p = Process(Logging; repeats = 1000)
    run(p)

    c = fetch(p)
    @test c isa ProcessContext
    log = c[Logger1].log
    @test log == c[pack].fiblist[2+100:100:end]
    @test length(log) == 10
end
