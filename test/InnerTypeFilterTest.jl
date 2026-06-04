using Test
using StatefulAlgorithms

@testset "inner_typefilter" begin
    tuple_input = ((1, "a"), (:x, 2), 3.0, ("b",))
    @test @inferred(StatefulAlgorithms.inner_typefilter(Int, tuple_input)) == ((1,), (2,))

    named_input = (; a = (1, "a"), b = (:x, 2), c = 3.0, d = ("b",))
    @test @inferred(StatefulAlgorithms.inner_typefilter(Int, named_input)) == (; a = (1,), b = (2,))
end
