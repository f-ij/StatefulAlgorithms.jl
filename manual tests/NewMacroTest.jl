include("_env.jl")

StatefulAlgorithms.@ProcessAlgorithmNew function CopyArray(a, @managed(buffer = type[]); @init((;type = Float64)))
    resize!(buffer, size(a)...)
    buffer .= a
    return 
end

StatefulAlgorithms.@ProcessAlgorithmNew function ProvideArray(@managed(array = type[]); @init (;type = Float64))
    resize!(array, 1000)
    array .= rand(1000)
    return
end

c1 = Unique(CopyArray())
c2 = Unique(CopyArray())

c = CompositeAlgorithm(ProvideArray, c1, c2, 
    Route(ProvideArray => c1, :array => :a),
    Route(ProvideArray => c2, :array => :a))
p = InlineProcess(c, Input(ProvideArray, type = Float32), Input(c1, type = Float32))
c = run(p)

