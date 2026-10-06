using Random

# EXPERIMENTAL context-delta loop: the loop carries only the persistent fields its steps can write (src/Context/Carry.jl),
# found by inference (src/Context/WriteLog.jl). These tests check that the write set is what the plan writes, that the
# results are right, and that the loop really takes the carrying path (it falls back silently otherwise).

# Reads an array and an rng from its context and flips one entry; returns a value that is not state.
struct DeltaReader <: ProcessAlgorithm end
StatefulAlgorithms.init(::DeltaReader, context) = (; x = rand(Xoshiro(2), Float32, 100), rng = Xoshiro(1))
function StatefulAlgorithms.step!(::DeltaReader, context)
    i = rand(context.rng, 1:100)
    context.x[i] = -context.x[i]
    return (; proposal = i)
end

# Writes its counter every step; its buffer is never written.
struct DeltaCounter <: ProcessAlgorithm end
StatefulAlgorithms.init(::DeltaCounter, context) = (; count = 0, buffer = zeros(10))
StatefulAlgorithms.step!(::DeltaCounter, context) = (; count = context.count + 1)

# An immutable struct of plain values and arrays, written as a whole.
struct DeltaSparse
    m::Int
    n::Int
    colptr::Vector{Int}
    nzval::Vector{Float32}
end
struct DeltaWriter <: ProcessAlgorithm end
StatefulAlgorithms.init(::DeltaWriter, context) = (; sp = DeltaSparse(10, 0, collect(1:11), ones(Float32, 10)))
StatefulAlgorithms.step!(::DeltaWriter, context) = (sp = context.sp; (; sp = DeltaSparse(sp.m, sp.n + 1, sp.colptr, sp.nzval)))

# Plain functions in DSL blocks: their returns write `@state` fields too.
delta_plus_one(x) = x + 1.0
delta_double(x) = 2x
const DELTA_OFFSET = 5.0

"""The write set the loop of `plan` gets: `_written_fields` asked the way `loop` asks it."""
function written_fields_of(plan)
    p = Process(plan; repeats = 10)
    captured = Ref{Any}(nothing)
    StatefulAlgorithms.makeloop!(p; threaded = false, loopfunc = (args...) -> (captured[] = args; nothing))
    wait(p.task)
    process, func, stored, lifetime, inputs, resume = captured[]
    step_plan = StatefulAlgorithms.getplan(func)
    return StatefulAlgorithms._written_fields(
        step_plan,
        StatefulAlgorithms._loop_cursor(process, step_plan, resume),
        StatefulAlgorithms._loop_state_context(stored, resume),
        StatefulAlgorithms._loop_runtime_context(inputs, process, lifetime, stored, resume),
        StatefulAlgorithms._root_wiring_view(func, step_plan),
        StatefulAlgorithms.Namespace{nothing}(),
        process,
        lifetime,
    )
end

"""Run `plan` for `n` steps as a `Process` and return its final context."""
function run_steps(plan, n)
    p = Process(plan; repeats = n)
    run(p)
    wait(p)
    return context(p)
end

@testset "Context delta: write sets" begin
    @test written_fields_of(CompositeAlgorithm(DeltaReader, (1,))) === Val(())
    @test written_fields_of(CompositeAlgorithm(DeltaCounter, (1,))) === Val(((:DeltaCounter_1, :count),))
    # A child on an interval writes on some ticks only: its field is in the write set anyway.
    @test written_fields_of(CompositeAlgorithm(DeltaReader, DeltaWriter, (1, 10))) === Val(((:DeltaWriter_1, :sp),))
    # A routine's repeats write the counter.
    @test written_fields_of(Routine(DeltaCounter, DeltaReader, (3, 2))) === Val(((:DeltaCounter_1, :count),))
end

@testset "Context delta: DSL function statements" begin
    writes_state = resolve(@CompositeAlgorithm begin
        @state x = 0.0
        x = delta_plus_one(x)
    end)
    output_only = resolve(@CompositeAlgorithm begin
        @state seed = 4.0
        result = delta_double(seed)
    end)
    assigns_state = resolve(@CompositeAlgorithm begin
        @state y = 1.0
        y = DELTA_OFFSET
    end)
    repeats_write_state = resolve(@Routine begin
        @state x = 0.0
        x = @repeat 3 delta_plus_one(x)
    end)

    @test written_fields_of(writes_state) === Val(((:_state, :x),))
    @test written_fields_of(output_only) === Val(())          # a function output that is not state is runtime-only
    @test written_fields_of(assigns_state) === Val(((:_state, :y),))
    @test written_fields_of(repeats_write_state) === Val(((:_state, :x),))

    @test run_steps(writes_state, 100)[:_state].x == 100.0
    @test run_steps(output_only, 100)[:_state].seed == 4.0
    @test run_steps(assigns_state, 100)[:_state].y == DELTA_OFFSET
    @test run_steps(repeats_write_state, 100)[:_state].x == 300.0
end

@testset "Context delta: results" begin
    # The same values as main's loop, which carries the whole context.
    @test run_steps(CompositeAlgorithm(DeltaCounter, (1,)), 1_000)[DeltaCounter].count == 1_000
    @test run_steps(CompositeAlgorithm(DeltaReader, DeltaWriter, (1, 10)), 1_000)[DeltaWriter].sp.n == 100
    @test run_steps(Routine(DeltaCounter, DeltaReader, (3, 2)), 100)[DeltaCounter].count == 3 * 100
end

@testset "Context delta: no allocation per step" begin
    for plan in (CompositeAlgorithm(DeltaReader, (1,)), CompositeAlgorithm(DeltaReader, DeltaWriter, (1, 10)),
                 Routine(DeltaCounter, DeltaReader, (3, 2)))
        run(InlineProcess(plan; repeats = 100))
        small = InlineProcess(plan; repeats = 1_000)
        large = InlineProcess(plan; repeats = 101_000)
        allocs_small = @allocated run(small)
        allocs_large = @allocated run(large)
        @test allocs_large - allocs_small < 1_000
    end
end

@testset "Context delta: the write set is a compile-time constant" begin
    p = Process(CompositeAlgorithm(DeltaReader, DeltaWriter, (1, 10)); repeats = 10)
    captured = Ref{Any}(nothing)
    StatefulAlgorithms.makeloop!(p; threaded = false, loopfunc = (args...) -> (captured[] = args; nothing))
    wait(p.task)
    code, _ = only(Base.code_typed(StatefulAlgorithms.loop, Tuple{map(typeof, captured[])...}; debuginfo = :none))
    typed = sprint(show, code)
    @test !occursin("return_type", typed)
    @test !occursin("_written_from_return_type", typed)
end

@testset "Context delta: only WriteLog.jl builds logged context types" begin
    # A write is lost only if a step returns a context that keeps a `WriteLog` type without recording the write.
    # Any other construction drops the log, which makes the plan carry its whole context.
    src = joinpath(pkgdir(StatefulAlgorithms), "src")
    for (root, _, files) in walkdir(src), file in files
        endswith(file, ".jl") || continue
        path = joinpath(root, file)
        file == "WriteLog.jl" && continue
        @test !occursin("WriteLog{", read(path, String))
    end
end
