using Test
using StatefulAlgorithms
using JLD2

@testset "savecontext / loadcontext via the JLD2 extension" begin
    struct SaveCounter <: ProcessAlgorithm end
    StatefulAlgorithms.init(::SaveCounter, context) = (; count = 0, history = Float64[])
    StatefulAlgorithms.step!(::SaveCounter, context) = (push!(context.history, context.count); (; count = context.count + 1))

    @test !isnothing(Base.get_extension(StatefulAlgorithms, :StatefulAlgorithmsJLD2Ext))

    p = Process(SaveCounter; repeats = 5)
    run(p); wait(p)
    file = tempname() * ".jld2"
    savecontext(p, file)
    data = loadcontext(file)
    @test data.SaveCounter_1.count == 5
    @test data.SaveCounter_1.history == [0.0, 1.0, 2.0, 3.0, 4.0]
    @test data == StatefulAlgorithms.contextdata(getcontext(p))
    close(p)
    rm(file; force = true)
end
