using Test
using StatefulAlgorithms

struct DisplayTreeAlgo <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::DisplayTreeAlgo, context::C) where {C<:StatefulAlgorithms.AbstractContext}
    return (;)
end

@testset "Context showing wraps prefixed lines to display width" begin
    buf = IOBuffer()
    io = IOContext(buf, :displaysize => (24, 20))
    StatefulAlgorithms._print_wrapped_prefixed(
        io,
        "state = IsingGraph{Float32, β, VeryLongTypeName}",
        "│    ├── ",
        "│    │   ",
    )

    output = split(chomp(String(take!(buf))), '\n')
    @test length(output) > 1
    @test all(Base.Unicode.textwidth(line) <= 20 for line in output)
    @test occursin("β", join(output, "\n"))
end

@testset "Process display hides LoopAlgorithm lifecycle type parameters" begin
    algo = CompositeAlgorithm(DisplayTreeAlgo, (1,))
    process = Process(algo; repeats = 1)

    output = sprint(show, MIME"text/plain"(), process)

    @test occursin("├── algo = CompositeAlgorithm", output)
    @test !occursin("algo = StatefulAlgorithms.LoopAlgorithm{", output)
    @test !occursin("NameSpaceRegistry{", output)
    @test occursin("Process(CompositeAlgorithm(DisplayTreeAlgo), lifetime=Repeat(1)", sprint(show, process))
end
