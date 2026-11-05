using Test
using StatefulAlgorithms

@testset "Symbol indexing and targeted init" begin
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
    ctx = init(resolved, ctx, Only(:SymbolInitAlgo_1), InitArgs(:SymbolInitAlgo_1; seed = 3))
    @test ctx[:SymbolInitAlgo_1].value == 3

    ctx = init(resolved, ctx, Only(:SymbolInitAlgo_1), InitArgs(:SymbolInitAlgo_1; seed = 7),
               Override(:SymbolInitAlgo_1; value = 11))
    @test ctx[:SymbolInitAlgo_1].value == 11

    p = Process(resolved, InitArgs(:SymbolInitAlgo_1, :seed => 1); repeats = 1)
    init!(p, Only(:SymbolInitAlgo_1), InitArgs(:SymbolInitAlgo_1; seed = 13))
    @test getcontext(p)[:SymbolInitAlgo_1].value == 13
    @test isempty(getcontext(p)[:SymbolOtherAlgo_1])
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
    ctx, _ = setup(resolved; lifetime = Repeat(1))
    keyed = StatefulAlgorithms.static_get(StatefulAlgorithms.getregistry(ctx), resolved[:view_alias])
    scv = view(StatefulAlgorithms.bundle_of(ctx), keyed)
    alias = StatefulAlgorithms.VarAliases(foo = :bar)
    aliased = StatefulAlgorithms.withaliases(scv, alias)

    @test StatefulAlgorithms.varaliases(aliased) === typeof(alias)
    @test StatefulAlgorithms.algo_to_subcontext_name(aliased, :bar) == :foo
    @test aliased.bar == 1
end
