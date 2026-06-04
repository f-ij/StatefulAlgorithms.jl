using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Printf
using Statistics
using Test
using StatefulAlgorithms

const BIG_DSL_STATEMENTS = parse(Int, get(ENV, "BIG_DSL_STATEMENTS", "120"))
const BIG_DSL_RUNS = parse(Int, get(ENV, "BIG_DSL_RUNS", "10"))
const BIG_DSL_WARMUPS = parse(Int, get(ENV, "BIG_DSL_WARMUPS", "2"))

"""Small scalar kernel used by every generated DSL statement."""
function big_dsl_mix(a::T, b::T; gain::T = one(T), bias::T = zero(T)) where {T<:AbstractFloat}
    return muladd(gain, sin(a + bias), T(0.73) * cos(b - bias)) + T(0.17) * a - T(0.09) * b
end

"""Fold two routed values into one scalar while avoiding trivial constant folding."""
function big_dsl_fold(a::T, b::T; gain::T = one(T)) where {T<:AbstractFloat}
    return muladd(T(0.91), a, T(0.07) * b) + gain * T(0.001)
end

"""Create one large `@Routine` expression with many ordinary DSL statements."""
function big_dsl_routine_expr(n::Int)
    statements = Any[
        LineNumberNode(@__LINE__, @__FILE__),
        :(@state seed = 0.125),
        :(@state anchor = 0.75),
    ]

    previous = :seed
    for i in 1:n
        output = Symbol(:v, i)
        gain = 1.0 + 0.0007 * i
        bias = 0.003 * i
        stmt = if i % 11 == 0
            # Keep explicit transform routes in the generated block; these are
            # common in large learning routines and stress route expansion.
            :($output = big_dsl_mix(@transform(x -> x + $bias, $previous), anchor; gain = $gain, bias = $bias))
        elseif i % 5 == 0
            :($output = big_dsl_fold($previous, anchor; gain = $gain))
        else
            :($output = big_dsl_mix($previous, anchor; gain = $gain, bias = $bias))
        end
        push!(statements, stmt)
        previous = output
    end

    push!(statements, :(result = big_dsl_fold($previous, seed; gain = 1.25)))
    block = Expr(:block, statements...)
    return Expr(:macrocall, Symbol("@Routine"), LineNumberNode(@__LINE__, @__FILE__), block)
end

"""Build and evaluate the large DSL routine in the current module."""
function big_dsl_build(n::Int)
    return eval(big_dsl_routine_expr(n))
end

"""Macroexpand the generated `@Routine` call in the current module."""
function big_dsl_macroexpand(ex)
    return macroexpand(@__MODULE__, ex)
end

"""Build the large DSL routine while timing parse, macro, and expanded eval."""
function big_dsl_build_breakdown(n::Int)
    expr_elapsed, ex = big_dsl_measure(() -> big_dsl_routine_expr(n))
    macro_elapsed, expanded = big_dsl_measure(() -> big_dsl_macroexpand(ex))
    eval_elapsed, algorithm = big_dsl_measure(() -> Base.invokelatest(eval, expanded))
    return (; expr_elapsed, macro_elapsed, eval_elapsed, algorithm)
end

"""Run the same scalar work without StatefulAlgorithms for a semantic checksum."""
function big_dsl_direct(n::Int)
    seed = 0.125
    anchor = 0.75
    previous = seed
    for i in 1:n
        gain = 1.0 + 0.0007 * i
        bias = 0.003 * i
        previous = if i % 11 == 0
            big_dsl_mix(previous + bias, anchor; gain, bias)
        elseif i % 5 == 0
            big_dsl_fold(previous, anchor; gain)
        else
            big_dsl_mix(previous, anchor; gain, bias)
        end
    end
    return big_dsl_fold(previous, seed; gain = 1.25)
end

"""Run one prepared `Process` synchronously and return the routed result."""
function big_dsl_runprocessinline!(process::P) where {P<:Process}
    reset!(process)
    StatefulAlgorithms.runprocessinline!(process)
    return StatefulAlgorithms.getglobals(fetch(process)).result
end

"""Return elapsed seconds and the value produced by a callable."""
function big_dsl_measure(callable::F) where {F}
    result = Ref{Any}()
    elapsed = @elapsed result[] = callable()
    return elapsed, result[]
end

"""Print a scalar diagnostic row in a diff-friendly format."""
function big_dsl_print(name::AbstractString, value)
    if value isa AbstractFloat
        @printf("%s=%.9f\n", name, value)
    else
        println(name, "=", value)
    end
    return nothing
end

"""Run the big-DSL statement count probe."""
function run_big_dsl_statement_probe()
    big_dsl_print("big_dsl_statements", BIG_DSL_STATEMENTS)
    big_dsl_print("big_dsl_runs", BIG_DSL_RUNS)
    big_dsl_print("big_dsl_warmups", BIG_DSL_WARMUPS)

    direct_elapsed, direct_result = big_dsl_measure(() -> big_dsl_direct(BIG_DSL_STATEMENTS))
    big_dsl_print("direct_seconds", direct_elapsed)
    big_dsl_print("direct_result", direct_result)

    build_elapsed, build_parts = big_dsl_measure(() -> Base.invokelatest(big_dsl_build_breakdown, BIG_DSL_STATEMENTS))
    algorithm = build_parts.algorithm
    big_dsl_print("dsl_expr_seconds", build_parts.expr_elapsed)
    big_dsl_print("dsl_macroexpand_seconds", build_parts.macro_elapsed)
    big_dsl_print("dsl_expanded_eval_seconds", build_parts.eval_elapsed)
    big_dsl_print("dsl_eval_seconds", build_elapsed)

    resolve_elapsed, resolved = big_dsl_measure(() -> Base.invokelatest(resolve, algorithm))
    big_dsl_print("resolve_seconds", resolve_elapsed)
    big_dsl_print("resolved_algorithm_count", length(StatefulAlgorithms.getalgos(StatefulAlgorithms.getplan(resolved))))

    construct_elapsed, process = big_dsl_measure(() -> Base.invokelatest(() -> Process(resolved; repeat = 1)))
    big_dsl_print("process_construct_seconds", construct_elapsed)

    cold_elapsed, cold_result = big_dsl_measure(() -> Base.invokelatest(big_dsl_runprocessinline!, process))
    big_dsl_print("cold_runprocessinline_seconds", cold_elapsed)
    big_dsl_print("cold_result", cold_result)

    for _ in 1:BIG_DSL_WARMUPS
        Base.invokelatest(big_dsl_runprocessinline!, process)
    end
    warm_samples = Float64[]
    sizehint!(warm_samples, BIG_DSL_RUNS)
    warm_result = cold_result
    for _ in 1:BIG_DSL_RUNS
        elapsed, warm_result = big_dsl_measure(() -> Base.invokelatest(big_dsl_runprocessinline!, process))
        push!(warm_samples, elapsed)
    end

    if isempty(warm_samples)
        big_dsl_print("warm_runprocessinline_median_seconds", NaN)
        big_dsl_print("warm_runprocessinline_min_seconds", NaN)
        big_dsl_print("warm_runprocessinline_max_seconds", NaN)
    else
        big_dsl_print("warm_runprocessinline_median_seconds", median(warm_samples))
        big_dsl_print("warm_runprocessinline_min_seconds", minimum(warm_samples))
        big_dsl_print("warm_runprocessinline_max_seconds", maximum(warm_samples))
    end
    big_dsl_print("warm_result", warm_result)

    @test cold_result ≈ direct_result rtol = 1e-10
    @test warm_result ≈ direct_result rtol = 1e-10
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_big_dsl_statement_probe()
end
