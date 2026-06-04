using Test
using Statistics
using StatefulAlgorithms

struct InlineFib <: StatefulAlgorithms.ProcessAlgorithm end
struct InlineLuc <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.step!(::InlineFib, context::C) where C
    fiblist = context.fiblist
    push!(fiblist, fiblist[end] + fiblist[end - 1])
    return nothing
end

function StatefulAlgorithms.init(::InlineFib, context::C) where C
    fiblist = Int[0, 1]
    processsizehint!(fiblist, context)
    return (;fiblist)
end

function StatefulAlgorithms.step!(::InlineLuc, context::C) where C
    luclist = context.luclist
    push!(luclist, luclist[end] + luclist[end - 1])
    return nothing
end

function StatefulAlgorithms.init(::InlineLuc, context::C) where C
    luclist = Int[2, 1]
    processsizehint!(luclist, context)
    return (;luclist)
end

function naive_fibluc(n)
    luclist = Int[2, 1]
    fiblist = Int[0, 1]
    sizehint!(fiblist, n + 2)
    sizehint!(luclist, n + 2)
    time_i = time_ns()
    for i in 1:n
        push!(fiblist, fiblist[end] + fiblist[end - 1])
        push!(luclist, luclist[end] + luclist[end - 1])
    end
    total_time = (time_ns() - time_i) / 1e9
    return total_time
end

function inline_bmark(ip::IP, trials = 5) where IP
    runtimes = Float64[]
    for _ in 1:trials
        @inline reset!(ip)
        start_ns = time_ns()
        @inline run(ip)
        elapsed = (time_ns() - start_ns) / 1e9
        push!(runtimes, elapsed)
    end
    return minimum(runtimes)
end
function inline_bmark_nogen(ip::IP, trials = 5) where IP
    runtimes = Float64[]
    for _ in 1:trials
        @inline reset!(ip)
        start_ns = time_ns()
        @inline StatefulAlgorithms.run_nogen(ip)
        elapsed = (time_ns() - start_ns) / 1e9
        push!(runtimes, elapsed)
    end
    return minimum(runtimes)
end


function naive_benchmark(trials = 5, n = 100_000)
    runtimes = Float64[]
    for _ in 1:trials
        elapsed = naive_fibluc(n)
        push!(runtimes, elapsed)
    end
    return minimum(runtimes)
end

@testset "InlineProcess benchmark" begin
    n = 100_000
    fibluc = StatefulAlgorithms.CompositeAlgorithm( InlineFib, InlineLuc , (1, 1))
    ip = StatefulAlgorithms.InlineProcess(fibluc; repeats = n)
    
    println("Benchmarking InlineProcess with $n repeats...")
    inline_bmark(ip, 5)
    inline_bmark_nogen(ip, 5)
    naive_benchmark(5, n)

    inline_time = inline_bmark(ip, 1000)
    naive_time = naive_benchmark(1000, n)
    nogen_time = inline_bmark_nogen(ip, 1000)
   
    @info "InlineProcess time: $inline_time s, NoGen time: $nogen_time s and Naive time: $naive_time s"
    @info "Non generated InlineProcess is $((nogen_time/inline_time)*100 ) % of Generated time"
    @info "InlineProcess time: $inline_time s and Naive time: $naive_time s"
    @info "InlineProcess is $((inline_time/naive_time)*100 ) % of Naive time"
    @info "NoGen InlineProcess is $((nogen_time/naive_time)*100 ) % of Naive time"
    @test inline_time <= naive_time * 1.2 || nogen_time <= naive_time * 1.2 
end
