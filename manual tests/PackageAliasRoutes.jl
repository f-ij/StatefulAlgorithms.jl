include("FibLucDef.jl")
import StatefulAlgorithms as ps

FibLuc = CompositeAlgorithm( (Fib, Luc), (1,1) )

struct FLMixer <:ProcessAlgorithm end
function ps.init(::FLMixer, input)
    mix = Int[]
    processsizehint!(mix, input)
    return (;mix)
end

function ps.step!(::FLMixer, context)
    (;fib, luc) = context
    push!(context.mix, fib[end] + luc[end])
    return
end

FLMixed = CompositeAlgorithm( (Fib, Luc, FLMixer), (1,1,1),
    Route(Fib, FLMixer, :fiblist => :fib), 
    Route(Luc, FLMixer, :luclist => :luc))



Pack = ps.Package(FLMixed, "FLMixerPack")
p = Process(Pack, lifetime = 100000)
start(p)

benchmark(Pack, 100000, 100; print_outer = true)
