using Test
using StatefulAlgorithms

@testset "Loop algorithm edit tools" begin
    struct EditAlgoA <: ProcessAlgorithm end
    struct EditAlgoB <: ProcessAlgorithm end
    struct EditAlgoC <: ProcessAlgorithm end
    struct EditState <: ProcessState end

    inner = CompositeAlgorithm(:left => EditAlgoA, EditAlgoB, (1, 2))
    outer = CompositeAlgorithm(inner, EditAlgoC, (3, 4))

    renamed = rename(outer, :left => :renamed_left)
    @test :renamed_left in keys(renamed)
    @test !(:left in keys(renamed))
    @test getkey(renamed.renamed_left) == :renamed_left

    inserted = insert(outer, 2, :middle => EditAlgoB, 5)
    @test length(getalgos(inserted)) == 4
    @test inserted[2] isa IdentifiableAlgo
    @test getkey(inserted[2]) == :middle
    @test interval(inserted, 1) == StatefulAlgorithms.Interval(3)
    @test interval(inserted, 2) == StatefulAlgorithms.Interval(5)
    @test interval(inserted, 3) == StatefulAlgorithms.Interval(6)
    @test interval(inserted, 4) == StatefulAlgorithms.Interval(4)

    retimed = changeinterval(outer, 2, 9)
    @test interval(retimed, 1) == StatefulAlgorithms.Interval(3)
    @test interval(retimed, 2) == StatefulAlgorithms.Interval(9)
    @test interval(retimed, 3) == StatefulAlgorithms.Interval(4)

    retimed_all = changeintervals(outer, (8, 9, 10))
    @test interval(retimed_all, 1) == StatefulAlgorithms.Interval(8)
    @test interval(retimed_all, 2) == StatefulAlgorithms.Interval(9)
    @test interval(retimed_all, 3) == StatefulAlgorithms.Interval(10)

    routine = Routine(EditAlgoA, EditAlgoB, (2, 3))
    extended_routine = addalgo(routine, :tail => EditAlgoC, 7)
    @test length(getalgos(extended_routine)) == 3
    @test repeats(extended_routine) == (2, 3, 7)
    @test getkey(extended_routine[3]) == :tail

    with_state = addstate(outer, :stateful => EditState)
    @test length(StatefulAlgorithms.getstates(with_state)) == 1
    @test getkey(only(StatefulAlgorithms.getstates(with_state))) == :stateful

    with_option = addoption(outer, Share(EditAlgoC, EditAlgoA))
    @test length(getoptions(with_option)) == length(getoptions(outer)) + 1
    @test only(getoptions(with_option, Share)) isa Share

    left = IdentifiableAlgo(EditAlgoA(), :left)
    right = IdentifiableAlgo(EditAlgoB(), :right)
    local_route = StatefulAlgorithms.LocalPlanOption(right, Route(left => right, :value))
    locally_wired = CompositeAlgorithm(left, right, (1, 1), local_route)
    locally_wired_wiring = StatefulAlgorithms.getwiring(locally_wired)
    @test isempty(StatefulAlgorithms.global_wiring(locally_wired_wiring))
    @test isempty(StatefulAlgorithms.child_wiring(locally_wired_wiring)[1])
    @test length(StatefulAlgorithms.routes(StatefulAlgorithms.child_wiring(locally_wired_wiring)[2])) == 1

    renamed_local = rename(locally_wired, :right => :renamed_right)
    renamed_wiring = StatefulAlgorithms.getwiring(renamed_local)
    @test isempty(StatefulAlgorithms.global_wiring(renamed_wiring))
    @test isempty(StatefulAlgorithms.child_wiring(renamed_wiring)[1])
    @test length(StatefulAlgorithms.routes(StatefulAlgorithms.child_wiring(renamed_wiring)[2])) == 1

    nested = Routine(EditAlgoA, EditAlgoB, (1, 1))
    object_target = EditAlgoC()
    object_route = StatefulAlgorithms.LocalPlanOption(object_target, Route(EditAlgoA() => object_target, :value))
    nested_local = CompositeAlgorithm(nested, object_target, (1, 1), object_route)
    nested_wiring = StatefulAlgorithms.getwiring(nested_local)
    @test StatefulAlgorithms.child_wiring(nested_wiring)[1] isa StatefulAlgorithms.PlanWiring
    @test length(StatefulAlgorithms.routes(StatefulAlgorithms.child_wiring(nested_wiring)[2])) == 1

    resolved = resolve(outer)
    @test_throws Exception insert(resolved, 1, EditAlgoA, 1)
    @test_throws Exception rename(resolved, :left => :nope)
end
