using Test
using StatefulAlgorithms

struct DSLSourceAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct DSLCombineAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct DSLSinkAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct DSLValueAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct DSLNestedSourceAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct DSLHeldStateAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct DSLRepeatLifetimeCounter <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.step!(::DSLSourceAlgo, context)
    return (; produced = 2, passthrough = context.seed)
end

function StatefulAlgorithms.step!(::DSLCombineAlgo, context)
    return (; combined = context.left + context.right)
end

function StatefulAlgorithms.step!(::DSLSinkAlgo, context)
    return (; seen = context.value)
end

function StatefulAlgorithms.step!(::DSLValueAlgo, context)
    return (; result = context.value)
end

function StatefulAlgorithms.step!(::DSLNestedSourceAlgo, context)
    return (; captured = 4)
end

function StatefulAlgorithms.init(::DSLHeldStateAlgo, context)
    return (; state = 11)
end

function StatefulAlgorithms.step!(::DSLHeldStateAlgo, context)
    return (; state = context.state)
end

function StatefulAlgorithms.init(::A, context::C) where {A<:DSLRepeatLifetimeCounter,C}
    return (; count = get(context, :count, 0))
end

function StatefulAlgorithms.step!(::A, context::C) where {A<:DSLRepeatLifetimeCounter,C}
    return (; count = context.count + 1)
end

scaled_double_dsl_test(x; scale = 1) = scale * (2x)
zero_input_dsl_test() = 7
keyword_only_capture_dsl_test(; plus_capture, minus_capture, β, buffers) = plus_capture + minus_capture + β + buffers
keyword_semicolon_dsl_test(; a, x, y) = a + 10x + 100y
literal_join_dsl_test(prefix, value, marker) = string(prefix, value, marker)
constant_value_dsl_test() = 0.25
square_dsl_test(x) = x^2
keyword_value_identity_dsl_test(; value) = value
dsl_final_summary(context) = (; result = context[DSLValueAlgo].result)
dsl_runtime_final_summary(context) = (; result = context.result)
dsl_state_push_writer!(buffers) = (push!(buffers, :writer); buffers)
dsl_state_push_reader!(buffers) = (push!(buffers, :reader); buffers)

@ProcessAlgorithm function DSLPositionalCallAlgo(value)
    return (; seen = value)
end

@ProcessAlgorithm function DSLKeywordCallAlgo(value; scale = 1)
    return (; seen = value * scale)
end

@testset "Composite DSL" begin
    @info "Composite DSL"
    @testset "FuncWrapper steps directly and does not eagerly init" begin
        @info "Composite DSL: FuncWrapper steps directly and does not eagerly init"
        wrapped = FuncWrapper(x -> 2x, (:x,), (:y,))
        @test StatefulAlgorithms.step!(wrapped, (; x = 4)) == (; y = 8)
        @test StatefulAlgorithms.init(wrapped, (; x = 4)) == (;)
        @test occursin("(x) -> (; y)", sprint(summary, wrapped))

        kw_wrapped = FuncWrapper((x; scale = 1) -> scale * x, (:external,), (:y,), (; scale = 3))
        @test StatefulAlgorithms.step!(kw_wrapped, (; external = 4)) == (; y = 12)
        @test StatefulAlgorithms.init(kw_wrapped, (; external = 4)) == (;)
        @test occursin("(external; scale = 3) -> (; y)", sprint(summary, kw_wrapped))

        kw_from_context = FuncWrapper((x; scale = 1) -> scale * x, (:external,), (:y,), (; scale = :factor))
        @test StatefulAlgorithms.step!(kw_from_context, (; external = 4, factor = 5)) == (; y = 20)
        @test StatefulAlgorithms.init(kw_from_context, (; external = 4, factor = 5)) == (;)

        kw_same_name = FuncWrapper((x; scale = 1) -> scale * x, (:external,), (:y,), (:scale,))
        @test StatefulAlgorithms.step!(kw_same_name, (; external = 4, scale = 6)) == (; y = 24)
        @test StatefulAlgorithms.init(kw_same_name, (; external = 4, scale = 6)) == (;)

        literal_wrapped = FuncWrapper(println, ("Num: ", :value), ())
        literal_show = sprint(show, literal_wrapped)
        literal_plain = sprint(io -> show(io, MIME("text/plain"), literal_wrapped))
        @test occursin("(\"Num: \", value) -> nothing", literal_show)
        @test occursin("function = println", literal_plain)
    end

    @testset "Inline state supports defaults and required inputs" begin
        @info "Composite DSL: Inline state supports defaults and required inputs"
        state = @state begin
            a = 1
            b
        end

        @test StatefulAlgorithms.init(state, (; b = 4)) == (; a = 1, b = 4)
        @test StatefulAlgorithms.init(state, (; a = 7, b = 4)) == (; a = 7, b = 4)
    end

    @testset "Mutable @state defaults are rebuilt per init" begin
        @info "Composite DSL: Mutable @state defaults are rebuilt per init"
        state = @state begin
            nums = Float64[]
        end

        first_init = StatefulAlgorithms.init(state, (;))
        push!(first_init.nums, 1.0)
        second_init = StatefulAlgorithms.init(state, (;))

        @test length(first_init.nums) == 1
        @test isempty(second_init.nums)
        @test first_init.nums !== second_init.nums
    end

    @testset "GeneralState merge combines disjoint state schemes" begin
        @info "Composite DSL: GeneralState merge combines disjoint state schemes"
        left = @state begin
            seed = 4
            scale
        end
        right = @state begin
            buffer = Float64[]
            offset = 2
        end

        merged = merge(left, right)
        init = StatefulAlgorithms.init(merged, (; scale = 3.0))

        @test init == (; seed = 4, scale = 3.0, buffer = Float64[], offset = 2)
        overlap_merged = @test_logs (:warn, r"Overlapping GeneralState field names") merge(left, @state begin
            seed = 7
        end)
        @test StatefulAlgorithms.init(overlap_merged, (; scale = 3.0)) == (; seed = 7, scale = 3.0)
    end

    @testset "Explicit state bind and merge document overlapping child state" begin
        @info "Composite DSL: Explicit state bind and merge document overlapping child state"
        writer = @Routine begin
            @state buffers
            buffers = dsl_state_push_writer!(buffers)
        end
        reader = @Routine begin
            @state buffers
            buffers = dsl_state_push_reader!(buffers)
        end

        implicit_overlap = @CompositeAlgorithm begin
            @context f = writer()
            @context n = reader()
        end

        @test_logs (:warn, r"f\.buffers <=> n\.buffers") resolve(implicit_overlap)

        bound = @CompositeAlgorithm begin
            @state buffers = Symbol[]
            @context f = writer()
            @context n = reader()
            @bind buffers => f.buffers
            @bind buffers => n.buffers
        end

        bound_process = Process(resolve(bound), repeat = 1)
        StatefulAlgorithms.run(bound_process)
        wait(bound_process)
        @test context(bound_process)[:_state].buffers == [:writer, :reader]

        merged_required = @CompositeAlgorithm begin
            @context f = writer()
            @context n = reader()
            @merge f.buffers, n.buffers
        end

        resolved_required = resolve(merged_required)
        @test_throws ErrorException init(resolved_required)
        initialized = init(resolved_required, Init(:_state; buffers = Symbol[]))
        merged_process = Process(initialized, repeat = 1)
        StatefulAlgorithms.run(merged_process)
        wait(merged_process)
        @test context(merged_process)[:_state].buffers == [:writer, :reader]

        explicit_state_path = @CompositeAlgorithm begin
            @context f = writer()
            @context n = reader()
            @merge f._state.buffers, n.buffers
        end

        @test_throws ErrorException init(resolve(explicit_state_path))

        left_default = @Routine begin
            @state buffers = Symbol[:left]
            buffers = dsl_state_push_writer!(buffers)
        end
        right_default = @Routine begin
            @state buffers = Symbol[:right]
            buffers = dsl_state_push_reader!(buffers)
        end
        default_conflict = @CompositeAlgorithm begin
            @context f = left_default()
            @context n = right_default()
            @merge f.buffers, n.buffers
        end

        @test_logs (:warn, r"multiple defaults") resolve(default_conflict)
    end

    @testset "CompositeAlgorithm DSL resolves and runs" begin
        @info "Composite DSL: CompositeAlgorithm DSL resolves and runs"
        n = 1
        algo = @CompositeAlgorithm begin
            @state seed = 3
            @state doubled = 10
            @alias source = DSLSourceAlgo
            produced, passthrough = source(seed = seed)
            doubled = @interval n scaled_double_dsl_test(produced; scale = 2)
            combined = DSLCombineAlgo(left = passthrough, right = doubled)
            DSLSinkAlgo(value = combined)
        end

        resolved = resolve(algo)

        @test resolved isa StatefulAlgorithms.LoopAlgorithm
        @test StatefulAlgorithms.getplan(resolved) isa CompositeAlgorithm
        @test isempty(StatefulAlgorithms.getoptions(algo, StatefulAlgorithms.Route))
        @test !isempty(StatefulAlgorithms.getoptions(StatefulAlgorithms.getplan(resolved), StatefulAlgorithms.Route))
        @test intervals(resolved) == (
            StatefulAlgorithms.Interval(1),
            StatefulAlgorithms.Interval(1),
            StatefulAlgorithms.Interval(1),
            StatefulAlgorithms.Interval(1),
        )
        @test StatefulAlgorithms.plan_child_namespace(resolved, 1) == :source
        @test length(StatefulAlgorithms.getstates(resolved)) == 1
        @test StatefulAlgorithms.getkey(first(StatefulAlgorithms.getstates(resolved))) == :_state

        sharedcontexts, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        @test !isempty(sharedvars)
        combine_routes = sharedvars[:DSLCombineAlgo_1]
        @test any(route -> StatefulAlgorithms.get_fromname(route) == :_runtime && StatefulAlgorithms.localnames(route) == (:right,), combine_routes)

        init_ctx = StatefulAlgorithms.initcontext(resolved; lifetime = Repeat(10))
        @test init_ctx[:_state].seed == 3
        @test init_ctx[:_state].doubled == 10

        process_repeat = Process(resolved, repeat = 10)
        @test repeats(StatefulAlgorithms.lifetime(process_repeat)) == 10

        process_indefinite = Process(resolved, repeat = Inf)
        @test StatefulAlgorithms.lifetime(process_indefinite) isa Indefinite

        p = Process(resolved, repeat = 10)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)

        @test ctx[:_state].seed == 3
        @test ctx[:_state].doubled == 10
        @test StatefulAlgorithms.getglobals(ctx).doubled == 8
        @test !haskey(StatefulAlgorithms.getglobals(context(p)), :doubled)
        @test ctx[:source].produced == 2
        @test ctx[:source].passthrough == 3
        @test ctx[:DSLCombineAlgo_1].combined == 11
        @test isempty(ctx[:DSLSinkAlgo_1])
    end

    @testset "Named state uses explicit key" begin
        @info "Composite DSL: Named state uses explicit key"
        named_state_algo = @CompositeAlgorithm begin
            @state mystate begin
                a = 1
            end
            DSLSinkAlgo(value = a)
        end

        resolved_named_state = resolve(named_state_algo)
        @test StatefulAlgorithms.getkey(first(StatefulAlgorithms.getstates(resolved_named_state))) == :mystate

        named_ctx = StatefulAlgorithms.initcontext(resolved_named_state)
        @test named_ctx[:mystate].a == 1
    end

    @testset "@all uses known alias keys in share endpoints" begin
        @info "Composite DSL: @all uses known alias keys in share endpoints"
        @ProcessAlgorithm function DSLShareSource(@managed(x = 1))
            return (; x)
        end

        @ProcessAlgorithm function DSLShareTarget(x)
            return nothing
        end

        expanded = macroexpand(@__MODULE__, quote
            @CompositeAlgorithm begin
                @alias osc = DSLShareSource
                osc()
                DSLShareTarget(@all(osc...))
            end
        end)
        expanded_str = sprint(show, Base.remove_linenums!(expanded))
        @test occursin("Share(", expanded_str)
        @test occursin("_composite_dsl_owner", expanded_str)
    end

    @testset "@route statements are top-level plan routes" begin
        @info "Composite DSL: @route statements are top-level plan routes"
        algo = @CompositeAlgorithm begin
            @state seed = 2
            @alias source = DSLSourceAlgo
            @alias sink = DSLSinkAlgo
            produced, passthrough = source(seed = seed)
            sink()
            @route source.produced => sink.value
        end

        @test algo isa StatefulAlgorithms.LoopAlgorithm
        plan = StatefulAlgorithms.getplan(algo)
        @test length(StatefulAlgorithms.getoptions(plan, StatefulAlgorithms.Route)) == 2
        plan_wiring = StatefulAlgorithms.getwiring(plan)
        @test length(StatefulAlgorithms.routes(StatefulAlgorithms.global_wiring(plan_wiring))) == 1
        @test length(StatefulAlgorithms.routes(StatefulAlgorithms.child_wiring(plan_wiring)[1])) == 1
        @test isempty(StatefulAlgorithms.child_wiring(plan_wiring)[2])

        resolved = resolve(algo)
        @test isempty(StatefulAlgorithms.getoptions(resolved, StatefulAlgorithms.Route))
        resolved_wiring = StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved))
        @test length(propertynames(StatefulAlgorithms.global_wiring(resolved_wiring))) == 1
        step_wiring = StatefulAlgorithms.child_wiring(resolved_wiring)
        sink_routes = @inferred StatefulAlgorithms.routes(step_wiring[2])
        @test step_wiring[2] isa StatefulAlgorithms.Wiring
        @test length(sink_routes) == 1
        @test StatefulAlgorithms.localnames(only(sink_routes)) == (:value,)

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test isempty(ctx[:sink])
        @test getkey(ctx[:sink]) == :sink
        @test StatefulAlgorithms.getdatatype(ctx[:sink]) <: NamedTuple
    end

    @testset "Local routes occlude top-level @route aliases" begin
        @info "Composite DSL: Local routes occlude top-level @route aliases"
        algo = @CompositeAlgorithm begin
            @state seed = 7
            @alias source = DSLSourceAlgo
            @alias sink = DSLSinkAlgo
            produced, passthrough = source(seed = seed)
            sink(value = passthrough)
            @route source.produced => sink.value
        end

        resolved = resolve(algo)
        step_wiring = StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved)))
        sink_routes = @inferred StatefulAlgorithms.routes(step_wiring[2])
        @test length(sink_routes) == 1
        @test StatefulAlgorithms.subvarcontextnames(only(sink_routes)) == (:passthrough,)

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test isempty(ctx[:sink])
        @test getkey(ctx[:sink]) == :sink
        @test StatefulAlgorithms.getdatatype(ctx[:sink]) <: NamedTuple
    end

    @testset "@route statements support reverse transforms" begin
        @info "Composite DSL: @route statements support reverse transforms"
        struct DSLReverseRouteSource <: StatefulAlgorithms.ProcessAlgorithm end
        struct DSLReverseRouteTarget <: StatefulAlgorithms.ProcessAlgorithm end

        StatefulAlgorithms.init(::DSLReverseRouteSource, context) = (; value = 1.0)
        StatefulAlgorithms.step!(::DSLReverseRouteSource, context) = (;)
        StatefulAlgorithms.init(::DSLReverseRouteTarget, context) = (;)
        StatefulAlgorithms.step!(::DSLReverseRouteTarget, context) = (; input = context.input + 2.0)

        algo = @CompositeAlgorithm begin
            @alias source = DSLReverseRouteSource
            @alias target = DSLReverseRouteTarget
            source()
            target()
            @route source.value => target.input transform = x -> 2x reverse_transform = x -> x / 2
        end

        resolved = resolve(algo)
        step_wiring = StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved)))
        target_routes = @inferred StatefulAlgorithms.routes(step_wiring[2])
        @test length(target_routes) == 1
        @test StatefulAlgorithms.gettransform(only(target_routes)) !== nothing
        @test StatefulAlgorithms.getreverse_transform(only(target_routes)) !== nothing

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test ctx[:source].value == 2.0
    end

    @testset "Transform routes use explicit @transform syntax" begin
        @info "Composite DSL: Transform routes use explicit @transform syntax"
        one_var_transform = @CompositeAlgorithm begin
            @state seed = 3
            @alias source = DSLSourceAlgo
            produced, passthrough = source(seed = seed)
            DSLSinkAlgo(value = @transform(x -> 3x, produced))
        end

        resolved_one_var = resolve(one_var_transform)
        _, one_var_opts = StatefulAlgorithms._resolve_options(resolved_one_var)
        one_var_routes = one_var_opts[:DSLSinkAlgo_1]
        @test length(one_var_routes) == 1
        @test StatefulAlgorithms.gettransform(first(one_var_routes)) !== nothing

        p_one_var = Process(resolved_one_var, repeat = 1)
        StatefulAlgorithms.run(p_one_var)
        ctx_one_var = fetch(p_one_var)
        @test isempty(ctx_one_var[:DSLSinkAlgo_1])

        bias = 3
        two_var_transform = @CompositeAlgorithm begin
            @state seed = 3
            @alias source = DSLSourceAlgo
            produced, passthrough = source(seed = seed)
            DSLValueAlgo(value = @transform(x -> x + bias, produced))
        end

        resolved_two_var = resolve(two_var_transform)
        _, two_var_opts = StatefulAlgorithms._resolve_options(resolved_two_var)
        two_var_routes = two_var_opts[:DSLValueAlgo_1]
        @test length(two_var_routes) == 1
        @test StatefulAlgorithms.gettransform(first(two_var_routes)) !== nothing

        p_two_var = Process(resolved_two_var, repeat = 1)
        StatefulAlgorithms.run(p_two_var)
        ctx_two_var = fetch(p_two_var)
        @test isempty(ctx_two_var[:DSLValueAlgo_1])
    end

    @testset "Implicit transform expressions are rejected in route syntax" begin
        @info "Composite DSL: Implicit transform expressions are rejected in route syntax"
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @CompositeAlgorithm begin
                @state seed = 3
                @alias source = DSLSourceAlgo
                produced, passthrough = source(seed = seed)
                DSLSinkAlgo(value = produced * 3)
            end
        end)
    end

    @testset "Scheduled assignment syntax error suggests RHS wrapper" begin
        @info "Composite DSL: Scheduled assignment syntax error suggests RHS wrapper"
        err = try
            macroexpand(@__MODULE__, quote
                @CompositeAlgorithm begin
                    @every 1 produced = DSLSourceAlgo()
                end
            end)
            nothing
        catch caught
            caught
        end

        @test err isa ErrorException
        msg = sprint(showerror, err)
        @test occursin("Invalid scheduled assignment", msg)
        @test occursin("produced = @every 1 DSLSourceAlgo()", msg)
    end

    @testset "Routine repeat form expands correctly" begin
        @info "Composite DSL: Routine repeat form expands correctly"
        routine = @Routine begin
            @state produced = 5
            tripled = @repeat 3 scaled_double_dsl_test(produced; scale = 3)
        end

        resolved_routine = resolve(routine)
        @test resolved_routine isa StatefulAlgorithms.LoopAlgorithm
        @test StatefulAlgorithms.getplan(resolved_routine) isa Routine
        @test repeats(resolved_routine) == (3,)
    end

    @testset "Routine repeat supports lifetime syntax with DSL selectors" begin
        @info "Composite DSL: Routine repeat supports lifetime syntax with DSL selectors"
        until_routine = @Routine begin
            count = @repeat Until(x -> x >= 3, count) DSLRepeatLifetimeCounter
        end

        until_result = run(until_routine; repeats = 1)
        @test StatefulAlgorithms.context(until_result)[DSLRepeatLifetimeCounter].count == 3

        until_ten_routine = @Routine begin
            count = @repeat Until(x -> x >= 10, count) DSLRepeatLifetimeCounter
        end

        until_ten_result = run(until_ten_routine; repeats = 1)
        @test StatefulAlgorithms.context(until_ten_result)[DSLRepeatLifetimeCounter].count == 10

        capped_routine = @Routine begin
            count = @repeat RepeatOrUntil(x -> x >= 10, 4, count) DSLRepeatLifetimeCounter
        end

        capped_result = run(capped_routine; repeats = 1)
        @test StatefulAlgorithms.context(capped_result)[DSLRepeatLifetimeCounter].count == 4

        repeat_routine = @Routine begin
            count = @repeat Repeat(2) DSLRepeatLifetimeCounter
        end

        repeat_result = run(repeat_routine; repeats = 1)
        @test StatefulAlgorithms.context(repeat_result)[DSLRepeatLifetimeCounter].count == 2

        atleast_routine = @Routine begin
            count = @repeat AtLeast(x -> x >= 1, 4, count) DSLRepeatLifetimeCounter
        end

        atleast_result = run(atleast_routine; repeats = 1)
        @test StatefulAlgorithms.context(atleast_result)[DSLRepeatLifetimeCounter].count == 4

        atleast_atmost_routine = @Routine begin
            count = @repeat AtLeastAtMost(x -> x >= 10, 2, 5, count) DSLRepeatLifetimeCounter
        end

        atleast_atmost_result = run(atleast_atmost_routine; repeats = 1)
        @test StatefulAlgorithms.context(atleast_atmost_result)[DSLRepeatLifetimeCounter].count == 5
    end

    @testset "Nested DSL state writeback resolves through keyed _state" begin
        @info "Composite DSL: Nested DSL state writeback resolves through keyed _state"
        inner = @Routine begin
            @state stored = 0
            stored = zero_input_dsl_test()
        end

        outer = @CompositeAlgorithm begin
            @state outer_flag = 1
            inner
        end

        resolved_outer = resolve(outer)
        @test resolved_outer isa StatefulAlgorithms.LoopAlgorithm
        @test StatefulAlgorithms.getplan(resolved_outer) isa CompositeAlgorithm
    end

    @testset "FuncWrapper positional args accept @context property routes" begin
        @info "Composite DSL: FuncWrapper positional args accept @context property routes"
        nested_identity(x) = x
        plus = @Routine begin
            @alias plus_capture = DSLNestedSourceAlgo
            plus_capture()
        end

        algo = @CompositeAlgorithm begin
            @context c1 = plus()
            result = nested_identity(c1.plus_capture.captured)
        end

        resolved = resolve(algo)
        wrapper = StatefulAlgorithms.getalgo(resolved, 2)
        wrapper_key = StatefulAlgorithms.plan_child_namespace(resolved, 2)
        _, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        routes = sharedvars[wrapper_key]
        @test length(routes) == 1
        @test occursin("c1.plus_capture.captured", sprint(show, wrapper))

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
        @test isempty(context(p)[wrapper_key])
        @test !haskey(StatefulAlgorithms.getglobals(context(p)), :result)
    end

    @testset "FuncWrapper positional args accept explicit @transform routes" begin
        @info "Composite DSL: FuncWrapper positional args accept explicit @transform routes"
        nested_identity(x) = x
        plus = @Routine begin
            @alias plus_capture = DSLNestedSourceAlgo
            plus_capture()
        end

        algo = @CompositeAlgorithm begin
            @context c1 = plus()
            result = nested_identity(@transform(x -> x + 1, c1.plus_capture.captured))
        end

        resolved = resolve(algo)
        wrapper = StatefulAlgorithms.getalgo(resolved, 2)
        wrapper_key = StatefulAlgorithms.plan_child_namespace(resolved, 2)
        @test occursin("@transform", sprint(show, wrapper))
        @test occursin("c1.plus_capture.captured", sprint(show, wrapper))

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "FuncWrapper positional @transform routes can source @state fields" begin
        @info "Composite DSL: FuncWrapper positional @transform routes can source @state fields"
        nested_identity(x) = x

        algo = @Routine begin
            @state clamping_beta = 2
            result = nested_identity(@transform(x -> -x, clamping_beta))
        end

        resolved = resolve(algo)
        wrapper = StatefulAlgorithms.getalgo(resolved, 1)
        wrapper_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        _, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        routes = sharedvars[wrapper_key]
        @test length(routes) == 1
        @test StatefulAlgorithms.gettransform(first(routes)) !== nothing
        @test occursin("@transform", sprint(show, wrapper))
        @test occursin("clamping_beta", sprint(show, wrapper))

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "State fields can be assigned captured values directly" begin
        @info "Composite DSL: State fields can be assigned captured values directly"
        somevar = 3

        algo = @Routine begin
            @state clamping_beta = 1.0
            clamping_beta = somevar
            result = keyword_value_identity_dsl_test(value = clamping_beta)
        end

        resolved = resolve(algo)
        writer = StatefulAlgorithms.getalgo(resolved, 1)
        writer_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        result_key = StatefulAlgorithms.plan_child_namespace(resolved, 2)
        @test writer isa StatefulAlgorithms.ContextWrite

        _, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        routes = sharedvars[writer_key]
        @test length(routes) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test ctx[:_state].clamping_beta === 3.0
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "State buffer indexes can be assigned directly" begin
        @info "Composite DSL: State buffer indexes can be assigned directly"

        algo = @Routine begin
            @state somebuffer = [0, 0, 0]
            somebuffer[1] = 2
            somebuffer[2:3] = [4, 5]
            result = keyword_value_identity_dsl_test(value = somebuffer)
        end

        resolved = resolve(algo)
        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test ctx[:_state].somebuffer == [2, 4, 5]
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "State buffers support broadcast assignment syntax" begin
        @info "Composite DSL: State buffers support broadcast assignment syntax"
        replacement = [7, 8]

        algo = @Routine begin
            @state somebuffer = [0, 0, 0]
            somebuffer .= 1
            somebuffer[2:3] .= replacement
            result = keyword_value_identity_dsl_test(value = somebuffer)
        end

        resolved = resolve(algo)
        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test ctx[:_state].somebuffer == [1, 7, 8]
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "Owned state fields can be assigned from ref values" begin
        @info "Composite DSL: Owned state fields can be assigned from ref values"
        nudged = @Routine begin
            @state nudged_beta = 0.0
            result = keyword_value_identity_dsl_test(value = nudged_beta)
        end

        algo = @CompositeAlgorithm begin
            @state clamping_beta = Ref(2.0)
            @alias nudged = nudged

            nudged.nudged_beta = clamping_beta[]
            nudged()
        end

        resolved = resolve(algo)
        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test ctx[:_state].nudged_beta === 2.0
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "FuncWrapper keyword args preserve routed display expressions" begin
        @info "Composite DSL: FuncWrapper keyword args preserve routed display expressions"
        plus = @Routine begin
            @alias plus_capture = DSLNestedSourceAlgo
            plus_capture()
        end

        algo = @CompositeAlgorithm begin
            @context c1 = plus()
            result = keyword_value_identity_dsl_test(value = c1.plus_capture.captured)
        end

        resolved = resolve(algo)
        wrapper = StatefulAlgorithms.getalgo(resolved, 2)
        @test occursin("value = c1.plus_capture.captured", sprint(show, wrapper))

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "FuncWrapper keyword args accept semicolon same-name syntax" begin
        @info "Composite DSL: FuncWrapper keyword args accept semicolon same-name syntax"
        algo = @CompositeAlgorithm begin
            @state b = 1
            @state x = 2
            @state y = 3
            result = keyword_semicolon_dsl_test(a = b; x, y)
            @finally dsl_runtime_final_summary
        end

        resolved = resolve(algo)
        wrapper = StatefulAlgorithms.getalgo(resolved, 1)
        wrapper_summary = sprint(show, wrapper)
        @test occursin("a = b", wrapper_summary)
        @test occursin("x = x", wrapper_summary)
        @test occursin("y = y", wrapper_summary)

        p = Process(resolved, repeat = 1)
        run(p)
        @test fetch(p) == (; result = 321)
        @test !haskey(StatefulAlgorithms.getglobals(context(p)), :result)
        close(p)
    end

    @testset "Alias field routes work before later output bindings" begin
        @info "Composite DSL: Alias field routes work before later output bindings"
        algo = @Routine begin
            @alias dynamics = DSLHeldStateAlgo()
            seen = DSLValueAlgo(value = dynamics.state)
            state = dynamics()
        end

        resolved = resolve(algo)
        sink = StatefulAlgorithms.getalgo(resolved, 1)
        sink_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        _, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        routes = sharedvars[sink_key]
        @test length(routes) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test isempty(ctx[sink_key])
        @test ctx[:dynamics].state == 11
    end

    @testset "Alias names can route owned fields without output bindings" begin
        @info "Composite DSL: Alias names can route owned fields without output bindings"
        algo = @Routine begin
            @alias dynamics = DSLHeldStateAlgo()
            @alias model_state = dynamics.state
            result = keyword_value_identity_dsl_test(value = model_state)
            doubled = scaled_double_dsl_test(model_state)
            transformed = keyword_value_identity_dsl_test(value = @transform(x -> x + 1, model_state))
            seen = DSLValueAlgo(value = model_state)
            dynamics()
        end

        resolved = resolve(algo)
        function_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        positional_key = StatefulAlgorithms.plan_child_namespace(resolved, 2)
        transform_key = StatefulAlgorithms.plan_child_namespace(resolved, 3)
        sink_key = StatefulAlgorithms.plan_child_namespace(resolved, 4)
        _, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        @test length(sharedvars[function_key]) == 1
        @test length(sharedvars[positional_key]) == 1
        @test StatefulAlgorithms.gettransform(first(sharedvars[transform_key])) !== nothing
        @test length(sharedvars[sink_key]) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :doubled)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :transformed)
        @test isempty(ctx[sink_key])
    end

    @testset "Nested repeat blocks inherit alias owned-field routes" begin
        @info "Composite DSL: Nested repeat blocks inherit alias owned-field routes"
        algo = @Routine begin
            @alias dynamics = DSLHeldStateAlgo()
            @repeat 2 begin
                result = keyword_value_identity_dsl_test(value = dynamics.state)
                doubled = scaled_double_dsl_test(dynamics.state)
            end
            dynamics()
        end

        resolved = resolve(algo)
        nested = StatefulAlgorithms.getalgo(resolved, 1)
        nested_plan = StatefulAlgorithms.getalgo(nested, 1)
        function_key = StatefulAlgorithms.plan_child_namespace(nested_plan, 1)
        positional_key = StatefulAlgorithms.plan_child_namespace(nested_plan, 2)
        _, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        @test length(sharedvars[function_key]) == 1
        @test length(sharedvars[positional_key]) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :doubled)
    end

    @testset "ProcessAlgorithm direct-call positional args accept alias field routes" begin
        @info "Composite DSL: ProcessAlgorithm direct-call positional args accept alias field routes"
        algo = @Routine begin
            @alias dynamics = DSLHeldStateAlgo()
            DSLPositionalCallAlgo(dynamics.state)
            state = dynamics()
        end

        resolved = resolve(algo)
        sink = StatefulAlgorithms.getalgo(resolved, 1)
        sink_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        _, sharedvars = StatefulAlgorithms._resolve_options(resolved)
        routes = sharedvars[sink_key]
        @test length(routes) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test isempty(ctx[sink_key])
        @test ctx[:dynamics].state == 11
    end

    @testset "state = dynamics.state aliases a known owned field" begin
        @info "Composite DSL: state = dynamics.state aliases a known owned field"
        algo = @Routine begin
            @alias dynamics = DSLHeldStateAlgo()
            state = dynamics.state
            seen = DSLValueAlgo(value = state)
            state = dynamics()
        end

        resolved = resolve(algo)
        sink = StatefulAlgorithms.getalgo(resolved, 1)
        sink_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test isempty(ctx[sink_key])
    end

    @testset "@include_if filters DSL entries at construction time" begin
        @info "Composite DSL: @include_if filters entries at construction time"
        include_source = false
        skipped = @CompositeAlgorithm begin
            @state seed = 3
            @include_if include_source produced, passthrough = DSLSourceAlgo(seed = seed)
            DSLValueAlgo(value = seed)
        end

        resolved_skipped = resolve(skipped)
        @test length(StatefulAlgorithms.getalgos(resolved_skipped)) == 1
        @test StatefulAlgorithms.intervals(resolved_skipped) == (StatefulAlgorithms.Interval(1),)
        @test isnothing(StatefulAlgorithms.findkey(resolved_skipped, :DSLSourceAlgo_1))

        p_skipped = Process(resolved_skipped, repeat = 1)
        StatefulAlgorithms.run(p_skipped)
        ctx_skipped = fetch(p_skipped)
        @test isempty(ctx_skipped[:DSLValueAlgo_1])

        include_source = true
        included = @CompositeAlgorithm begin
            @state seed = 3
            @include_if include_source produced, passthrough = DSLSourceAlgo(seed = seed)
            DSLValueAlgo(value = produced)
        end

        resolved_included = resolve(included)
        @test length(StatefulAlgorithms.getalgos(resolved_included)) == 2
        @test !isnothing(StatefulAlgorithms.findkey(resolved_included, :DSLSourceAlgo_1))

        p_included = Process(resolved_included, repeat = 1)
        StatefulAlgorithms.run(p_included)
        ctx_included = fetch(p_included)
        @test isempty(ctx_included[:DSLValueAlgo_1])
    end

    @testset "@include_if supports blocks, schedules, and routines" begin
        @info "Composite DSL: @include_if supports blocks, schedules, and routines"
        include_block = true
        block_algo = @CompositeAlgorithm begin
            @state seed = 3
            @include_if include_block begin
                produced, passthrough = @interval 2 DSLSourceAlgo(seed = seed)
                DSLSinkAlgo(value = produced)
            end
            DSLValueAlgo(value = seed)
        end

        resolved_block = resolve(block_algo)
        @test length(StatefulAlgorithms.getalgos(resolved_block)) == 3
        @test StatefulAlgorithms.intervals(resolved_block) == (
            StatefulAlgorithms.Interval(2),
            StatefulAlgorithms.Interval(1),
            StatefulAlgorithms.Interval(1),
        )

        include_block = false
        routine = @Routine begin
            @state produced = 5
            @include_if include_block tripled = @repeat 3 scaled_double_dsl_test(produced; scale = 3)
            DSLValueAlgo(value = produced)
        end

        resolved_routine = resolve(routine)
        @test length(StatefulAlgorithms.getalgos(resolved_routine)) == 1
        @test repeats(resolved_routine) == (1,)
    end

    @testset "@include_if supports branch-local @context" begin
        @info "Composite DSL: @include_if supports branch-local @context"
        plus = @Routine begin
            @alias plus_capture = DSLNestedSourceAlgo
            plus_capture()
        end

        include_context = true
        algo = @CompositeAlgorithm begin
            @include_if include_context begin
                @context c1 = plus()
                result = keyword_value_identity_dsl_test(value = c1.plus_capture.captured)
            end
        end

        resolved = resolve(algo)
        @test length(StatefulAlgorithms.getalgos(resolved)) == 2

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        wrapper = StatefulAlgorithms.getalgo(resolved, 2)
        @test !haskey(StatefulAlgorithms.getglobals(ctx), :result)
    end

    @testset "@include_if rejects state and alias declarations" begin
        @info "Composite DSL: @include_if rejects state and alias declarations"
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @CompositeAlgorithm begin
                @include_if true begin
                    @state seed = 3
                    DSLValueAlgo(value = seed)
                end
            end
        end)

        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @CompositeAlgorithm begin
                @include_if true begin
                    @alias source = DSLSourceAlgo
                    source()
                end
            end
        end)
    end

    @testset "@finally wraps only the outer DSL algorithm" begin
        @info "Composite DSL: @finally wraps only the outer DSL algorithm"
        algo = @CompositeAlgorithm begin
            @state seed = 8
            DSLValueAlgo(value = seed)
            @finally dsl_final_summary
        end

        @test algo isa StatefulAlgorithms.FinalizedAlgorithm
        resolved = resolve(algo)
        p = Process(resolved, repeat = 1)
        run(p)
        @test fetch(p) == (; result = 8)
        @test isempty(context(p)[DSLValueAlgo])

        close(p)
        @test fetch(p) == (; result = 8)

        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @CompositeAlgorithm begin
                DSLValueAlgo(value = 1)
                @finally dsl_final_summary
                @finally dsl_final_summary
            end
        end)

        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @CompositeAlgorithm begin
                @include_if true begin
                    DSLValueAlgo(value = 1)
                    @finally dsl_final_summary
                end
            end
        end)

        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @CompositeAlgorithm begin
                result = @repeat 2 begin
                    DSLValueAlgo(value = 1)
                    @finally dsl_final_summary
                end
            end
        end)
    end

    @testset "FuncWrapper outputs are runtime-only and visible to finalstep" begin
        @info "Composite DSL: FuncWrapper outputs are runtime-only and visible to finalstep"
        algo = @CompositeAlgorithm begin
            @state seed = 4
            result = keyword_value_identity_dsl_test(value = seed)
            @finally dsl_runtime_final_summary
        end

        p = Process(resolve(algo), repeat = 1)
        run(p)
        @test fetch(p) == (; result = 4)
        @test isempty(context(p)[:FuncWrapper_1])
        @test !haskey(StatefulAlgorithms.getglobals(context(p)), :result)

        close(p)
        @test fetch(p) == (; result = 4)
        @test !haskey(StatefulAlgorithms.getglobals(context(p)), :result)
    end

    @testset "FuncWrapper runtime output shape does not persist" begin
        @info "Composite DSL: FuncWrapper runtime output shape does not persist"
        count = Ref(0)
        widening_runtime_value = () -> begin
            count[] += 1
            count[] == 1 ? (; y = 1) : (; y = 1, z = 2)
        end

        algo = @CompositeAlgorithm begin
            result = widening_runtime_value()
        end

        p = Process(resolve(algo), repeat = 2)
        run(p)
        fetched = fetch(p)

        @test fetched isa StatefulAlgorithms.ProcessContext
        @test !haskey(StatefulAlgorithms.getglobals(fetched), :result)
        @test count[] == 2
        @test isempty(context(p)[:FuncWrapper_1])
        @test !haskey(StatefulAlgorithms.getglobals(context(p)), :result)
        close(p)
    end
end
