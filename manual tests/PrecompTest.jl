using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using StatefulAlgorithms
struct Fib <: ProcessAlgorithm end
struct Luc <: ProcessAlgorithm end

function StatefulAlgorithms.step!(::Fib, context)
    fiblist = context.fiblist
    push!(fiblist, fiblist[end] + fiblist[end-1])
    return (;)
end

function StatefulAlgorithms.init(::Fib, context)
    n_calls = num_calls(context)
    fiblist = Int[0, 1]
    processsizehint!(fiblist, context)
    return (;fiblist)
end

function StatefulAlgorithms.step!(::Luc, context)
    luclist = context.luclist
    push!(luclist, luclist[end] + luclist[end-1])
    return (;)
end

function StatefulAlgorithms.init(::Luc, context)
    luclist = Int[2, 1]
    processsizehint!(luclist,context)
    return (;luclist)
end


Fdup = Unique(Fib())
Ldup = Unique(Luc)


FibLuc = CompositeAlgorithm( (Fib(), Fib, Luc), (1,1,2), Route(Fib(), Luc, :fiblist))

C = Routine((Fib, Fib(), FibLuc), (10,20,30))

FFluc = CompositeAlgorithm( (FibLuc, Fdup, Fib, Ldup), (10,5,2,1), Route(Fdup, Ldup, :fiblist), Share(Fib, Ldup))

pfu = Process(FFluc)
pcu = Process(C)
run(pfu)
close(pfu)
run(pcu)
close(pcu)

pfr = Process(FFluc, lifetime = 1)
pcr = Process(C, lifetime = 1)

pack = package(FibLuc)
p = Process(pack)
run(p)
close(p)
pr = Process(pack, lifetime = 1)
run(pr)
