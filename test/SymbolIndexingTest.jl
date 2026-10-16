using Test
using StatefulAlgorithms

@testset "Symbol indexing and targeted initcontext" begin
    # `value` is initialised from the init-time input `seed`
    @StepAlgorithm function SymbolInitAlgo(@managed(value = context.seed))
        return
    end
    @StepAlgorithm function SymbolOtherAlgo()
        return
    end

    resolved = resolve(CompositeAlgorithm(SymbolInitAlgo, SymbolOtherAlgo, (1, 1)))
    reg = getregistry(resolved)

    @test StatefulAlgorithms.getalgo(reg[:SymbolInitAlgo_1]) == resolved[:SymbolInitAlgo_1]
    @test resolved[:SymbolInitAlgo_1] == resolved.SymbolInitAlgo_1
    @test StatefulAlgorithms.getkey(reg[:SymbolOtherAlgo_1]) == :SymbolOtherAlgo_1

    ctx = ProcessContext(resolved)
    ctx = initcontext(ctx, :SymbolInitAlgo_1; inputs = (; seed = 3))
    @test ctx[:SymbolInitAlgo_1].value == 3

    ctx = initcontext(ctx, resolved[:SymbolInitAlgo_1]; inputs = (; seed = 7), overrides = (; value = 11))
    @test ctx[:SymbolInitAlgo_1].value == 11

    p = Process(resolved, Input(:SymbolInitAlgo_1, :seed => 1); repeats = 1)
    reinit(p, :SymbolInitAlgo_1; inputs = (; seed = 13))
    wait(p)
    @test context(p)[:SymbolInitAlgo_1].value == 13
    @test isempty(context(p)[:SymbolOtherAlgo_1])
end

@testset "ProcessContext properties expose subcontexts without storage-field collisions" begin
    ctx = StatefulAlgorithms.ProcessContext(
        (;
            reg = StatefulAlgorithms.SubContext(:reg, (; value = 1)),
            registry = StatefulAlgorithms.SubContext(:registry, (; value = 2)),
            subcontexts = StatefulAlgorithms.SubContext(:subcontexts, (; value = 3)),
        ),
        nothing,
    )

    @test propertynames(ctx) == (:reg, :registry, :subcontexts)
    @test ctx.reg.value == 1
    @test ctx.registry.value == 2
    @test ctx.subcontexts.value == 3
    @test isnothing(StatefulAlgorithms.getregistry(ctx))
    @test keys(StatefulAlgorithms.get_subcontexts(ctx)) == (:reg, :registry, :subcontexts)
end

@testset "SubContextView aliases can be replaced from alias type" begin
    @StepAlgorithm function ViewAliasAlgo(@managed(foo = 1))
        return
    end

    resolved = resolve(CompositeAlgorithm(:view_alias => ViewAliasAlgo(), (1,)))
    ctx = initcontext(resolved; lifetime = Repeat(1))
    keyed = StatefulAlgorithms.static_get(StatefulAlgorithms.getregistry(ctx), resolved[:view_alias])
    scv = view(StatefulAlgorithms.bundle_of(ctx), keyed)
    alias = StatefulAlgorithms.VarAliases(foo = :bar)
    aliased = StatefulAlgorithms.withaliases(scv, alias)

    @test StatefulAlgorithms.varaliases(aliased) === typeof(alias)
    @test StatefulAlgorithms.algo_to_subcontext_name(aliased, :bar) == :foo
    @test aliased.bar == 1
end
