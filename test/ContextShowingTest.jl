using Test
using StatefulAlgorithms

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
