using Test
using StatefulAlgorithms

"""
Documented step algorithm for macro docstring tests.
"""
@StepAlgorithm function DocumentedStepAlgorithmForTest(value)
    return value
end

"""
Documented config-backed step algorithm for macro docstring tests.
"""
@StepAlgorithm @config offset::Int = 1 function DocumentedConfiguredStepAlgorithmForTest(value)
    return value + offset
end

@testset "StepAlgorithm macro docstrings" begin
    documented = sprint(show, MIME"text/plain"(), @doc(DocumentedStepAlgorithmForTest))
    configured = sprint(show, MIME"text/plain"(), @doc(DocumentedConfiguredStepAlgorithmForTest))

    @test occursin("Documented step algorithm", documented)
    @test occursin("Documented config-backed step algorithm", configured)
    @test DocumentedStepAlgorithmForTest <: StepAlgorithm
    @test DocumentedConfiguredStepAlgorithmForTest <: StepAlgorithm
    @test DocumentedStepAlgorithmForTest <: ProcessAlgorithm
end

@testset "ProcessAlgorithm macro deprecation alias" begin
    @test_logs (:warn, r"`@ProcessAlgorithm` is deprecated") @eval begin
        @ProcessAlgorithm function DeprecatedProcessAlgorithmMacroForTest(value)
            return value
        end
    end

    @test DeprecatedProcessAlgorithmMacroForTest <: StepAlgorithm
    @test StatefulAlgorithms.step!(DeprecatedProcessAlgorithmMacroForTest(), 3) == 3
end

@testset "StepAlgorithm macro inputs and managed capture" begin
    @StepAlgorithm function CaptureInput(
        a,
        @managed(c = b^2),
        @managed(b);
        @init((; b = 1))
    )
        @update b = b + a
        @update c = c + b
        return a + b + c
    end

    prepared = StatefulAlgorithms.init(CaptureInput(), (; b = 3))
    @test prepared.b == 3
    @test prepared.c == 9

    # In a plan, a step returns its value and its updates.
    stepped = StatefulAlgorithms.step!(CaptureInput(), (; a = 2, b = prepared.b, c = prepared.c))
    @test stepped isa StepReturn
    @test StatefulAlgorithms.step_updates(stepped) == (; b = 5, c = 14)
    @test StatefulAlgorithms.step_value(stepped) == 21
    @test updated_names(CaptureInput) == (:b, :c)

    # Called directly, it returns its value.
    @test StatefulAlgorithms.step!(CaptureInput(), 2; @init((; b = 4))) == 30
end

@testset "@inputs and @input are deprecated aliases of @init" begin
    @test_logs (:warn, r"`@inputs\(\(; \.\.\.\)\)` is deprecated") @eval begin
        @StepAlgorithm function DeprecatedInitAliasForTest(a, @managed(b); @inputs((; b = 2)))
            return a + b
        end
    end
    @test StatefulAlgorithms.init(DeprecatedInitAliasForTest(), (;)) == (; b = 2)
    @test StatefulAlgorithms.step!(DeprecatedInitAliasForTest(), 1; @input((; b = 5))) == 6
end

@testset "StepAlgorithm macro: a @managed initializer reads @init values" begin
    @StepAlgorithm function InitValues(
        a,
        @managed(c = b + 1),
        @managed(b);
        @init((; b = 2))
    )
        return (; total = a + b + c)
    end

    prepared = StatefulAlgorithms.init(InitValues(), (;))
    @test prepared.b == 2
    @test prepared.c == 3

    stepped = StatefulAlgorithms.step!(InitValues(), (; a = 5, b = prepared.b, c = prepared.c))
    @test StatefulAlgorithms.step_value(stepped).total == 10
end

@testset "StepAlgorithm macro can capture managed values directly from init context" begin
    @StepAlgorithm function ContextCapture(
        x,
        @managed(state),
        @managed(dt),
        @managed(velocity = 0.0);
        @init((; dt = 0.1))
    )
        @update state = state + dt + velocity + x
    end

    prepared = StatefulAlgorithms.init(ContextCapture(), (; state = 1.0))
    @test prepared.state == 1.0
    @test prepared.dt == 0.1
    @test prepared.velocity == 0.0

    stepped = StatefulAlgorithms.step!(ContextCapture(), (; x = 0.0, state = prepared.state, dt = prepared.dt, velocity = prepared.velocity))
    @test StatefulAlgorithms.step_updates(stepped).state == 1.1
    @test isnothing(StatefulAlgorithms.step_value(stepped))   # a body ending in `@update` returns nothing
end

@testset "StepAlgorithm macro supports grouped @managed declarations" begin
    @StepAlgorithm function GroupedManaged(
        a,
        @managed(b, c = b + 1, d = nothing);
        @init((; b = 2))
    )
        return (; total = a + b + c, d_value = d)
    end

    prepared = StatefulAlgorithms.init(GroupedManaged(), (;))
    @test prepared.b == 2
    @test prepared.c == 3
    @test isnothing(prepared.d)

    stepped = StatefulAlgorithms.step!(GroupedManaged(), (; a = 5, b = prepared.b, c = prepared.c, d = prepared.d))
    @test StatefulAlgorithms.step_value(stepped).total == 10
    @test isnothing(StatefulAlgorithms.step_value(stepped).d_value)
end

@testset "StepAlgorithm macro supports where signatures" begin
    resetstate!(graph::AbstractVector) = fill!(graph, 0)

    @StepAlgorithm function resetgraph!(isinggraph::G) where G
        resetstate!(isinggraph)
        return
    end

    graph = [1, 2, 3]
    StatefulAlgorithms.step!(resetgraph!(), graph)
    @test graph == [0, 0, 0]

    graph2 = [4, 5]
    StatefulAlgorithms.step!(resetgraph!(), (; isinggraph = graph2))
    @test graph2 == [0, 0]
end

# Config fields with and without a declared type, for the test below (top level: a struct type).
@StepAlgorithm begin
    @config gain = 2.0
    @config scale <: Real = 3
    @config label::Symbol = :a
    function TypedConfigForTest(@managed(x = 0.0))
        return (; x = x * 0.5 + gain * scale)
    end
end

@testset "StepAlgorithm @config fields are always typed" begin
    # `gain = 2.0`: a type parameter, the type of the value; `scale <: Real = 3`: a bounded one; `label::Symbol`: as declared.
    @test TypedConfigForTest() isa TypedConfigForTest{Float64, Int64}
    @test fieldtypes(typeof(TypedConfigForTest())) == (Float64, Int64, Symbol)
    @test TypedConfigForTest(gain = 1f0) isa TypedConfigForTest{Float32, Int64}
    @test_throws MethodError TypedConfigForTest(scale = "three")
    # A run of it is inferred: the config values are not `Any`.
    ip = InlineProcess(TypedConfigForTest(); repeats = 10)
    @test isconcretetype(Base.return_types(run, (typeof(ip),))[1])
    run(ip)
    @test StatefulAlgorithms.context(ip)[:TypedConfigForTest_1].x ≈ 12 * (1 - 0.5^10)
end

@testset "StepAlgorithm macro supports @config-backed structs" begin
    @StepAlgorithm @config seed::Int = 3 begin
        @config begin
            width::Int = 2
        end
        function ConfiguredNoise(
            target,
            @managed(buffer = fill(seed, width));
            gain = 1,
            @init((;))
        )
            total = target + sum(buffer) + gain + seed + width
            return (; total, seed, width)
        end
    end

    algo = ConfiguredNoise(seed = 5, width = 4)
    @test algo.seed == 5
    @test algo.width == 4

    prepared = StatefulAlgorithms.init(algo, (;))
    @test prepared.buffer == fill(5, 4)

    direct = StatefulAlgorithms.step!(algo, 2; gain = 3)
    @test direct.total == 34
    @test direct.seed == 5
    @test direct.width == 4

    stepped = StatefulAlgorithms.step!(algo, (; target = 2, buffer = prepared.buffer, gain = 3))
    @test StatefulAlgorithms.step_value(stepped) == direct
end

# Config fields with and without a declared type, for the test below (top level: a struct type).
@StepAlgorithm begin
    @config gain = 2.0
    @config scale <: Real = 3
    @config label::Symbol = :a
    function TypedConfigForTest(@managed(x = 0.0))
        @update x = x * 0.5 + gain * scale
    end
end

@testset "StepAlgorithm @config fields are always typed" begin
    # `gain = 2.0`: a type parameter, the type of the value; `scale <: Real = 3`: a bounded one; `label::Symbol`: as declared.
    @test TypedConfigForTest() isa TypedConfigForTest{Float64, Int64}
    @test fieldtypes(typeof(TypedConfigForTest())) == (Float64, Int64, Symbol)
    @test TypedConfigForTest(gain = 1f0) isa TypedConfigForTest{Float32, Int64}
    @test_throws MethodError TypedConfigForTest(scale = "three")
    @test StatefulAlgorithms.updated_names(typeof(TypedConfigForTest())) == (:x,)
    # A run of it is inferred: the config values are not `Any`.
    ip = InlineProcess(TypedConfigForTest(); repeats = 10)
    @test isconcretetype(Base.return_types(run, (typeof(ip),))[1])
    run(ip)
    @test StatefulAlgorithms.context(ip)[:TypedConfigForTest_1].x ≈ 12 * (1 - 0.5^10)
end

@testset "StepAlgorithm macro @inline opt-in" begin
    inline_name = Expr(:., :Base, QuoteNode(Symbol("@inline")))
    function has_inline(ex)
        ex isa Expr || return false
        ex.head == :macrocall && ex.args[1] == inline_name && return true
        return any(has_inline, ex.args)
    end
    expand(ex) = macroexpand(@__MODULE__, ex; recursive = false)   # keep the generated @inline unexpanded

    # not forced by default
    @test !has_inline(expand(:(@StepAlgorithm function PlainForInlineTest(x) return x end)))
    # forced in every accepted position
    @test has_inline(expand(:(@StepAlgorithm @inline function InlineDirectForTest(x) return x end)))
    @test has_inline(expand(:(@StepAlgorithm @config k = 1 @inline function InlineConfigForTest(x) return x + k end)))
    @test has_inline(expand(:(@StepAlgorithm begin
        @config k = 1
        @inline function InlineBlockForTest(x)
            return x + k
        end
    end)))

    # the algorithm behaves the same
    @StepAlgorithm @inline function InlinedAccumulatorForTest(x, @managed(total = 0.0))
        @update total += x
        return total
    end
    algo = InlinedAccumulatorForTest()
    @test StatefulAlgorithms.init(algo, (;)).total == 0.0
    @test StatefulAlgorithms.step_updates(StatefulAlgorithms.step!(algo, (; x = 2.0, total = 1.0))).total == 3.0
end

abstract type SupertypeForMacroTest <: StepAlgorithm end
@StepAlgorithm @inline function WithSupertypeForTest(x, @managed(total = start); @init((; start = 0.0))) <: SupertypeForMacroTest
    @update total += x
    return total
end
@StepAlgorithm begin
    @config k = 2
    function BlockWithSupertypeForTest(x) <: SupertypeForMacroTest
        return k * x
    end
end
@StepAlgorithm function WhereWithSupertypeForTest(x::X) where {X} <: SupertypeForMacroTest
    return 2x
end

@testset "StepAlgorithm macro <: supertype" begin
    @test WithSupertypeForTest <: SupertypeForMacroTest
    @test BlockWithSupertypeForTest <: SupertypeForMacroTest
    @test WhereWithSupertypeForTest <: SupertypeForMacroTest
    @test StatefulAlgorithms.init(WithSupertypeForTest(), (; start = 1.0)).total == 1.0
    @test StatefulAlgorithms.step_updates(StatefulAlgorithms.step!(WithSupertypeForTest(), (; x = 2.0, total = 1.0))).total == 3.0
    @test StatefulAlgorithms.step_value(StatefulAlgorithms.step!(BlockWithSupertypeForTest(), (; x = 3))) == 6
    @test StatefulAlgorithms.step_value(StatefulAlgorithms.step!(WhereWithSupertypeForTest(), (; x = 3))) == 6
end
