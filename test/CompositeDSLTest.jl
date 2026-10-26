using Test
using StatefulAlgorithms
using StatefulAlgorithms: Callable   # internal: tests build calls directly

# Returns `(; produced = 2, passthrough = seed)`; no state.
@StepAlgorithm function DSLSourceAlgo(seed)
    return (; produced = 2, passthrough = seed)
end

# Returns `(; combined = left + right)`; no state.
@StepAlgorithm function DSLCombineAlgo(left, right)
    return (; combined = left + right)
end

# Returns `(; seen = value)`; no state.
@StepAlgorithm function DSLSinkAlgo(value)
    return (; seen = value)
end

# Writes `value` to the runtime name `result` (visible to `@finally`, not state).
@StepAlgorithm function DSLValueAlgo(value; result = nothing)
    @update result = value
end

# Keeps 4 in its state field `captured`.
@StepAlgorithm function DSLNestedSourceAlgo(@managed(captured = 0))
    @update captured = 4
end

# Keeps 2 in its state field `produced`, for routes that read it (`@route source.produced => …`); returns
# `(; produced, passthrough = seed)`.
@StepAlgorithm function DSLRouteSourceAlgo(seed, @managed(produced = 0))
    @update produced = 2
    return (; produced, passthrough = seed)
end
record_returns_dsl_test!(seen, values...) = (push!(seen, values); nothing)

# Keeps 11 in its state field `state`.
@StepAlgorithm function DSLHeldStateAlgo(@managed(state = 11))
    @update state
end

# Counts its steps in its state field `count` and returns the new count.
@StepAlgorithm function DSLRepeatLifetimeCounter(@managed(count = 0))
    @update count = count + 1
    return count
end

scaled_double_dsl_test(x; scale = 1) = scale * (2x)
zero_input_dsl_test() = 7
keyword_only_capture_dsl_test(; plus_capture, minus_capture, β, buffers) = plus_capture + minus_capture + β + buffers
keyword_semicolon_dsl_test(; a, x, y) = a + 10x + 100y
literal_join_dsl_test(prefix, value, marker) = string(prefix, value, marker)
constant_value_dsl_test() = 0.25
square_dsl_test(x) = x^2
plus100_dsl_test(v) = v + 100.0
keep_value_dsl_test(v) = v
plus_one_dsl_test(v) = v + 1.0
push_four_dsl_test(seen, a, b, c, d) = (push!(seen, (a, b, c, d)); seen)
@StepAlgorithm function DSLLocalBump(x)
    return x + 1.0
end
push_seen_dsl_test(seen, v) = (push!(seen, v); seen)
@StepAlgorithm function DSLManagedCounter(@managed(x = 0.0))
    @update x = x + 1.0
end
keyword_value_identity_dsl_test(; value) = value
dsl_final_summary(context) = (; result = context[DSLValueAlgo].result)
dsl_runtime_final_summary(context) = (; result = context.result)
dsl_state_push_writer!(buffers) = (push!(buffers, :writer); buffers)
dsl_state_push_reader!(buffers) = (push!(buffers, :reader); buffers)
@StepAlgorithm function DSLRedirectSourceAlgo(@managed(x = 1.0))
    @update x = x + 1
end
@StepAlgorithm function DSLRedirectSinkAlgo(@managed(y = 0.0, seen = 0.0))
    @update seen = y
end

@StepAlgorithm function DSLPositionalCallAlgo(value)
    return (; seen = value)
end

@StepAlgorithm function DSLKeywordCallAlgo(value; scale = 1)
    return (; seen = value * scale)
end

@testset "Composite DSL" begin
    @info "Composite DSL"
    @testset "Callable steps directly and does not eagerly init" begin
        @info "Composite DSL: Callable steps directly and does not eagerly init"
        wrapped = Callable(x -> 2x, (:x,), :y)
        @test StatefulAlgorithms.step!(wrapped, (; x = 4)) == (; y = 8)
        @test StatefulAlgorithms.init(wrapped, (; x = 4)) == (;)
        @test occursin("y = ", sprint(summary, wrapped)) && occursin("(x))", sprint(summary, wrapped))

        kw_wrapped = Callable((x; scale = 1) -> scale * x, (:external,), (; scale = 3), :y)
        @test StatefulAlgorithms.step!(kw_wrapped, (; external = 4)) == (; y = 12)
        @test StatefulAlgorithms.init(kw_wrapped, (; external = 4)) == (;)
        @test occursin("(external; scale = 3))", sprint(summary, kw_wrapped))

        kw_from_context = Callable((x; scale = 1) -> scale * x, (:external,), (; scale = :factor), :y)
        @test StatefulAlgorithms.step!(kw_from_context, (; external = 4, factor = 5)) == (; y = 20)
        @test StatefulAlgorithms.init(kw_from_context, (; external = 4, factor = 5)) == (;)

        kw_same_name = Callable((x; scale = 1) -> scale * x, (:external,), (; scale = :scale), :y)
        @test StatefulAlgorithms.step!(kw_same_name, (; external = 4, scale = 6)) == (; y = 24)
        @test StatefulAlgorithms.init(kw_same_name, (; external = 4, scale = 6)) == (;)

        literal_wrapped = Callable(println, ("Num: ", :value), ())
        literal_show = sprint(show, literal_wrapped)
        literal_plain = sprint(io -> show(io, MIME("text/plain"), literal_wrapped))
        @test occursin("Callable(println(\"Num: \", value))", literal_show)
        @test occursin("println", literal_plain)
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

    @testset "@bind, @merge and @redirect share state explicitly" begin
        @info "Composite DSL: @bind, @merge and @redirect share state explicitly"
        writer = @Routine begin
            @state buffers
            buffers = dsl_state_push_writer!(buffers)
        end
        reader = @Routine begin
            @state buffers
            buffers = dsl_state_push_reader!(buffers)
        end
        # Every state namespace => its fields
        state_data(ctx) = (subcontexts = getfield(ctx, :subcontexts);
            Dict(k => getfield(getfield(subcontexts, k), :data) for k in keys(subcontexts) if startswith(string(k), "_state_")))
        steps(plan, n = 1) = StatefulAlgorithms.context(run(plan; repeats = n))

        # Without any of them, two blocks' fields named `buffers` are two fields
        separate = resolve(@CompositeAlgorithm(begin
            @context f = writer()
            @context n = reader()
        end))
        @test count(k -> startswith(string(k), "_state_"), keys(states(separate))) == 2

        # `@bind x => c.x`: in the block, `c.x` is this block's `x`; the nested states lose the bound field
        bound = @CompositeAlgorithm begin
            @state buffers = Symbol[]
            @context f = writer()
            @context n = reader()
            @bind buffers => f.buffers
            @bind buffers => n.buffers
        end
        @test state_data(steps(bound)) == Dict(:_state_1 => (; buffers = [:writer, :reader]))

        # Several mappings, other field names, and a scope: only what the `begin ... end` builds is bound
        free_writer = @Routine begin
            @state buffers = Symbol[]
            buffers = dsl_state_push_writer!(buffers)
        end
        scoped = @CompositeAlgorithm begin
            @state log = Symbol[]
            @bind log => f.buffers log => n.buffers begin
                @context f = writer()
                @context n = reader()
            end
            @context g = free_writer()
        end
        @test Set(values(state_data(steps(scoped)))) == Set([(; log = [:writer, :reader]), (; buffers = [:writer])])

        # An algorithm's own field as the target: it reads the bound value instead of its own `y` (0.0)
        bound_algo = @CompositeAlgorithm begin
            @state level = 7.0
            @alias sink = DSLRedirectSinkAlgo
            sink()
            @bind level => sink.y
        end
        @test steps(bound_algo)[:sink].seen == 7.0

        # `@merge c1, c2`: the nested blocks' states become one state, matched by both
        merged = resolve(@CompositeAlgorithm(begin
            @context f = writer()
            @context n = reader()
            @merge f, n
        end))
        name = only(keys(states(merged)))
        @test_throws ErrorException init(merged)    # `buffers` is required by both
        @test state_data(StatefulAlgorithms.context(run(init(merged, Init(name; buffers = Symbol[])); repeats = 1))) ==
            Dict(name => (; buffers = [:writer, :reader]))

        # `@merge` takes whole states; one field is shared with `@bind` or `@redirect`
        @test_throws Exception @eval @CompositeAlgorithm begin
            @context f = $writer()
            @context n = $reader()
            @merge f.buffers, n.buffers
        end

        # A state value made once and added to several blocks is one state: it has one identity
        shared_state_add!(eq, x) = (eq .+= x; nothing)
        phase = Unique(@state begin
            total = zeros(3)
            x
        end)
        forward = @Routine begin
            @alias ps = phase
            ps
            shared_state_add!(ps.total, ps.x)
        end
        backward = @Routine begin
            @alias ps = phase
            ps
            shared_state_add!(ps.total, ps.x)
        end
        both = resolve(@CompositeAlgorithm(begin
            forward()
            backward()
        end))
        @test keys(states(both)) == (:ps,)          # keyed by its alias
        # Also when the blocks are nested with `@context`, which gives their states other diagnostic paths
        @test_logs min_level = Base.CoreLogging.Warn resolve(@CompositeAlgorithm(begin
            @context f = forward()
            @context b = backward()
        end))
        ctx = StatefulAlgorithms.context(run(init(both, Init(:ps; x = [1.0, 2.0, 3.0])); repeats = 2))
        @test ctx[:ps].total == [4.0, 8.0, 12.0]    # 2 steps of 2 blocks

        # `@redirect` is an option of its block, also when that block is nested
        inner = @CompositeAlgorithm begin
            @alias a = DSLRedirectSourceAlgo
            @alias b = DSLRedirectSinkAlgo
            a()
            b()
            @redirect a.x => b.y
        end
        ctx = steps(@CompositeAlgorithm(begin
            inner()
        end), 3)
        @test ctx[:b].seen == ctx[:a].x == 4.0
    end

    @testset "CompositeAlgorithm DSL resolves and runs" begin
        @info "Composite DSL: CompositeAlgorithm DSL resolves and runs"
        n = 1
        recorded = Any[]
        algo = @CompositeAlgorithm begin
            @state seed = 3
            @state doubled = 10
            @alias source = DSLSourceAlgo
            (; produced, passthrough) = source(seed = seed)
            doubled = @interval n scaled_double_dsl_test(produced; scale = 2)
            (; combined) = DSLCombineAlgo(left = passthrough, right = doubled)
            DSLSinkAlgo(value = combined)
            record_returns_dsl_test!(recorded, produced, passthrough, doubled, combined)
        end

        resolved = resolve(algo)

        @test resolved isa StatefulAlgorithms.LoopAlgorithm
        @test StatefulAlgorithms.getplan(resolved) isa Plan
        # Before resolve the block is its plan, holding its routes and its `@state`
        @test algo isa Plan
        @test length(StatefulAlgorithms.getstates(algo)) == 1
        @test !isempty(StatefulAlgorithms.get_routes(algo))
        @test !isempty(StatefulAlgorithms.get_routes(StatefulAlgorithms.getplan(resolved)))
        # Each algorithm statement with names on the left is followed by the call that captures its return.
        @test intervals(resolved) == ntuple(_ -> StatefulAlgorithms.Interval(1), 7)
        @test StatefulAlgorithms.plan_child_namespace(resolved, 1) == :source
        @test length(StatefulAlgorithms.getstates(resolved)) == 1
        @test StatefulAlgorithms._composite_dsl_is_block_state(first(StatefulAlgorithms.getstates(resolved)))

        sharedcontexts, sharedvars = StatefulAlgorithms._resolved_wiring_by_target(resolved)
        @test !isempty(sharedvars)
        combine_routes = sharedvars[:DSLCombineAlgo_1]
        @test any(route -> StatefulAlgorithms.source_namespace(route) == :_captured_returns && StatefulAlgorithms.getaliases(route) == (:right,), combine_routes)

        init_ctx = StatefulAlgorithms.initcontext(resolved; lifetime = Repeat(10))
        @test init_ctx[:_state_1].seed == 3
        @test init_ctx[:_state_1].doubled == 10

        process_repeat = Process(resolved, repeat = 10)
        @test repeats(StatefulAlgorithms.lifetime(process_repeat)) == 10

        process_indefinite = Process(resolved, repeat = Inf)
        @test StatefulAlgorithms.lifetime(process_indefinite) isa Indefinite

        p = Process(resolved, repeat = 10)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)

        @test ctx[:_state_1].seed == 3
        @test ctx[:_state_1].doubled == 10
        # Returns live for one step of their block: read in the step (an algorithm's return is captured into the
        # block's scope, as a call's is), gone after the run.
        @test last(recorded) == (2, 3, 8, 11)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :doubled)
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
        @StepAlgorithm function DSLShareSource(@managed(x = 1))
            return x
        end

        @StepAlgorithm function DSLShareTarget(x)
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
            @alias source = DSLRouteSourceAlgo
            @alias sink = DSLSinkAlgo
            source(seed = seed)
            sink()
            @route source.produced => sink.value
        end

        @test algo isa Plan
        plan = StatefulAlgorithms.getplan(algo)
        @test length(StatefulAlgorithms.get_routes(plan)) == 2
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
        @test StatefulAlgorithms.getaliases(only(sink_routes)) == (:value,)

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
            @alias source = DSLRouteSourceAlgo
            @alias sink = DSLSinkAlgo
            (; produced, passthrough) = source(seed = seed)
            sink(value = passthrough)
            @route source.produced => sink.value
        end

        resolved = resolve(algo)
        step_wiring = StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved)))
        sink_routes = @inferred StatefulAlgorithms.routes(step_wiring[3])   # 2 is the capture of `source`'s return
        @test length(sink_routes) == 1
        @test StatefulAlgorithms.source_fieldnames(only(sink_routes)) == (:passthrough,)

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test isempty(ctx[:sink])
        @test getkey(ctx[:sink]) == :sink
        @test StatefulAlgorithms.getdatatype(ctx[:sink]) <: NamedTuple
    end

    @testset "@route statements support reverse transforms" begin
        @info "Composite DSL: @route statements support reverse transforms"
        @StepAlgorithm function DSLReverseRouteSource(@managed(value = 1.0))
            return
        end
        # Writes `input + 2.0` back through the route to `source.value`.
        @StepAlgorithm function DSLReverseRouteTarget(input)
            @update input = input + 2.0
        end

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
            (; produced, passthrough) = source(seed = seed)
            DSLSinkAlgo(value = @transform(x -> 3x, produced))
        end

        resolved_one_var = resolve(one_var_transform)
        _, one_var_opts = StatefulAlgorithms._resolved_wiring_by_target(resolved_one_var)
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
            (; produced, passthrough) = source(seed = seed)
            DSLValueAlgo(value = @transform(x -> x + bias, produced))
        end

        resolved_two_var = resolve(two_var_transform)
        _, two_var_opts = StatefulAlgorithms._resolved_wiring_by_target(resolved_two_var)
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
                (; produced, passthrough) = source(seed = seed)
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
            @repeat 3 scaled_double_dsl_test(produced; scale = 3)
        end

        resolved_routine = resolve(routine)
        @test resolved_routine isa StatefulAlgorithms.LoopAlgorithm
        @test StatefulAlgorithms.getplan(resolved_routine) isa Plan
        @test repeats(resolved_routine) == (3,)

        # `x = @repeat n f()` is the repeated block `@repeat n begin x = f() end`, with `local x` before it.
        assigned_routine = @Routine begin
            @state produced = 5
            tripled = @repeat 3 scaled_double_dsl_test(produced; scale = 3)
        end
        block_routine = @Routine begin
            @state produced = 5
            local tripled
            @repeat 3 begin
                tripled = scaled_double_dsl_test(produced; scale = 3)
            end
        end
        @test sprint(show, StatefulAlgorithms.getplan(resolve(assigned_routine))) == sprint(show, StatefulAlgorithms.getplan(resolve(block_routine)))

        seen = Int[]
        run(@Routine(begin
            @state produced = 5
            tripled = @repeat 3 scaled_double_dsl_test(produced; scale = 3)
            push!(seen, tripled)
        end); repeats = 1)
        @test seen == [30]
    end

    @testset "Routine repeat supports lifetime syntax with DSL selectors" begin
        @info "Composite DSL: Routine repeat supports lifetime syntax with DSL selectors"
        # The condition reads the counter's state explicitly (`Var(Algo, :field)`); `n = …` inside the repeated block
        # captures the return of the last repeat into the local `n`, which `seen` records.
        counter_state(result) = StatefulAlgorithms.context(result)[DSLRepeatLifetimeCounter].count

        seen = Int[]
        until_result = run(@Routine(begin
            local n
            @repeat Until(x -> x >= 3, Var(DSLRepeatLifetimeCounter, :count)) begin
                n = DSLRepeatLifetimeCounter()
            end
            push!(seen, n)
        end); repeats = 1)
        @test counter_state(until_result) == 3
        @test seen == [3]

        seen = Int[]
        until_ten_result = run(@Routine(begin
            local n
            @repeat Until(x -> x >= 10, Var(DSLRepeatLifetimeCounter, :count)) begin
                n = DSLRepeatLifetimeCounter()
            end
            push!(seen, n)
        end); repeats = 1)
        @test counter_state(until_ten_result) == 10
        @test seen == [10]

        seen = Int[]
        capped_result = run(@Routine(begin
            local n
            @repeat RepeatOrUntil(x -> x >= 10, 4, Var(DSLRepeatLifetimeCounter, :count)) begin
                n = DSLRepeatLifetimeCounter()
            end
            push!(seen, n)
        end); repeats = 1)
        @test counter_state(capped_result) == 4
        @test seen == [4]

        seen = Int[]
        repeat_result = run(@Routine(begin
            local n
            @repeat Repeat(2) begin
                n = DSLRepeatLifetimeCounter()
            end
            push!(seen, n)
        end); repeats = 1)
        @test counter_state(repeat_result) == 2
        @test seen == [2]

        seen = Int[]
        atleast_result = run(@Routine(begin
            local n
            @repeat AtLeast(x -> x >= 1, 4, Var(DSLRepeatLifetimeCounter, :count)) begin
                n = DSLRepeatLifetimeCounter()
            end
            push!(seen, n)
        end); repeats = 1)
        @test counter_state(atleast_result) == 4
        @test seen == [4]

        seen = Int[]
        atleast_atmost_result = run(@Routine(begin
            local n
            @repeat AtLeastAtMost(x -> x >= 10, 2, 5, Var(DSLRepeatLifetimeCounter, :count)) begin
                n = DSLRepeatLifetimeCounter()
            end
            push!(seen, n)
        end); repeats = 1)
        @test counter_state(atleast_atmost_result) == 5
        @test seen == [5]

        # A name in the condition is a block value, never the repeated algorithm's state field of that name.
        err = try
            @eval @Routine begin
                @repeat Until(x -> x >= 3, count) DSLRepeatLifetimeCounter()
            end
            nothing
        catch e
            e
        end
        @test !isnothing(err) && occursin("Lifetime selector `count` is not a block value", sprint(showerror, err))

        # The condition is checked before every repeat, as a `while` loop's: when it already holds, the child does not run.
        already_met = run(@Routine(begin
            @repeat Until(x -> x >= 0, Var(DSLRepeatLifetimeCounter, :count)) DSLRepeatLifetimeCounter()
        end); repeats = 1)
        @test counter_state(already_met) == 0
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
        @test StatefulAlgorithms.getplan(resolved_outer) isa Plan
    end

    @testset "Nested blocks keep their state and wiring when flattened into the parent" begin
        @info "Composite DSL: Nested blocks keep their state and wiring when flattened into the parent"
        flatten_inc_dsl_test(x) = x + 1
        make_a() = @CompositeAlgorithm begin
            @state a = 1
            a = flatten_inc_dsl_test(a)
        end
        make_b() = @CompositeAlgorithm begin
            @state b = 10
            b = flatten_inc_dsl_test(b)
        end
        # The value of state field `name`, in whichever namespace holds it
        function state_value(ctx, name)
            subcontexts = getfield(ctx, :subcontexts)
            for k in keys(subcontexts)
                data = getfield(getfield(subcontexts, k), :data)
                hasproperty(data, name) && return getproperty(data, name)
            end
            error("no state field $name")
        end
        steps(plan, n) = StatefulAlgorithms.context(run(plan; repeats = n))

        by_hand = steps(CompositeAlgorithm(make_a(), make_b(), (1, 1)), 3)
        @test state_value(by_hand, :a) == 4
        @test state_value(by_hand, :b) == 13

        a, b = make_a(), make_b()
        with_dsl = steps(@CompositeAlgorithm(begin
            a()
            b()
        end), 3)
        @test state_value(with_dsl, :a) == 4
        @test state_value(with_dsl, :b) == 13
    end

    @testset "Each construction of a block has its own state" begin
        @info "Composite DSL: Each construction of a block has its own state"
        identity_inc_dsl_test(x) = x + 1
        make() = @CompositeAlgorithm begin
            @state a = 1
            a = identity_inc_dsl_test(a)
        end
        # Every state namespace (`_state_1`, `_state_2`, ...) => its field `a`
        state_values(ctx) = (subcontexts = getfield(ctx, :subcontexts);
            Dict(k => getfield(getfield(subcontexts, k), :data).a for k in keys(subcontexts) if startswith(string(k), "_state_")))
        steps(plan, n) = StatefulAlgorithms.context(run(plan; repeats = n))

        b1, b2 = make(), make()
        # Two constructions: two states, each stepped 3 times
        two = @test_logs steps(@CompositeAlgorithm(begin
            b1()
            b2()
        end), 3)
        @test state_values(two) == Dict(:_state_1 => 4, :_state_2 => 4)
        @test state_values(steps(CompositeAlgorithm(b1, b2, (1, 1)), 3)) == Dict(:_state_1 => 4, :_state_2 => 4)

        # The same block twice: one state, stepped 4 + 2 times
        same = steps(@CompositeAlgorithm(begin
            b1()
            @interval 2 b1()
        end), 4)
        @test state_values(same) == Dict(:_state_1 => 7)
        @test state_values(steps(CompositeAlgorithm(b1, b1, (1, 2)), 4)) == Dict(:_state_1 => 7)

        # `states(la)`: every state of the resolved tree once, by namespace
        resolved = resolve(@CompositeAlgorithm(begin
            b1()
            b2()
            @interval 2 b1()
        end))
        flat = @inferred states(resolved)
        @test keys(flat) == (:_state_1, :_state_2)
        @test all(s -> s isa GeneralState, values(flat))
        @test_throws ErrorException states(b1)
    end

    @testset "Function call positional args accept @context property routes" begin
        @info "Composite DSL: Function call positional args accept @context property routes"
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
        _, sharedvars = StatefulAlgorithms._resolved_wiring_by_target(resolved)
        routes = sharedvars[wrapper_key]
        @test length(routes) == 1
        @test occursin("nested_identity(plus_capture.captured)", sprint(show, StatefulAlgorithms.getplan(resolved)))   # the plan prints a call with its wires as argument sources

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
        @test isempty(context(p)[wrapper_key])
        @test !haskey(StatefulAlgorithms.get_captured_returns(context(p)), :result)
    end

    @testset "Function call positional args accept explicit @transform routes" begin
        @info "Composite DSL: Function call positional args accept explicit @transform routes"
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
        @test occursin("@transform", sprint(show, StatefulAlgorithms.getplan(resolved)))
        @test occursin("plus_capture.captured", sprint(show, StatefulAlgorithms.getplan(resolved)))

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
    end

    @testset "Function call positional @transform routes can source @state fields" begin
        @info "Composite DSL: Function call positional @transform routes can source @state fields"
        nested_identity(x) = x

        algo = @Routine begin
            @state clamping_beta = 2
            result = nested_identity(@transform(x -> -x, clamping_beta))
        end

        resolved = resolve(algo)
        wrapper = StatefulAlgorithms.getalgo(resolved, 1)
        wrapper_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        _, sharedvars = StatefulAlgorithms._resolved_wiring_by_target(resolved)
        routes = sharedvars[wrapper_key]
        @test length(routes) == 1
        @test StatefulAlgorithms.gettransform(first(routes)) !== nothing
        @test occursin("@transform", sprint(show, StatefulAlgorithms.getplan(resolved)))
        @test occursin("_state_1.clamping_beta", sprint(show, StatefulAlgorithms.getplan(resolved)))

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
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

        _, sharedvars = StatefulAlgorithms._resolved_wiring_by_target(resolved)
        routes = sharedvars[writer_key]
        @test length(routes) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test ctx[:_state_1].clamping_beta === 3.0
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
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
        @test ctx[:_state_1].somebuffer == [2, 4, 5]
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
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
        @test ctx[:_state_1].somebuffer == [1, 7, 8]
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
    end

    @testset "State buffers can broadcast from other state buffers" begin
        @info "Composite DSL: State buffers can broadcast from other state buffers"

        algo = @Routine begin
            @state sourcebuffer = [2, 4, 6]
            @state targetbuffer = [0, 0, 0]
            targetbuffer .= sourcebuffer
            targetbuffer[2:3] .= sourcebuffer[1:2]
            result = keyword_value_identity_dsl_test(value = targetbuffer)
        end

        resolved = resolve(algo)
        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test ctx[:_state_1].targetbuffer == [2, 2, 4]
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
    end

    @testset "Owned state fields can be assigned from a call, every step" begin
        @info "Composite DSL: Owned state fields can be assigned from a call, every step"
        run_steps(algo, n) = (p = Process(resolve(algo), repeat = n); run(p); ctx = fetch(p); close(p); ctx)

        # Each step: the counter adds 1 to its managed `x`, then the call writes x + 100 back into it.
        ctx = run_steps(@CompositeAlgorithm(begin
            @alias c = DSLManagedCounter
            c()
            c.x = plus100_dsl_test(c.x)
        end), 3)
        @test ctx[:c].x == 303.0

        ctx = run_steps(@CompositeAlgorithm(begin
            @alias c = DSLManagedCounter
            c()
            c.x = c.x * 2.0
        end), 3)
        @test ctx[:c].x == 14.0

        # On a schedule: the call runs on steps 2 and 4 only.
        ctx = run_steps(@CompositeAlgorithm(begin
            @alias c = DSLManagedCounter
            c()
            c.x = @every 2 plus100_dsl_test(c.x)
        end), 4)
        @test ctx[:c].x == 204.0
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
        @test ctx[:_state_1].clamping_beta[] === 2.0
        @test ctx[:_state_2].nudged_beta === 2.0   # `nudged`'s own state
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
    end

    @testset "Function call keyword args preserve routed display expressions" begin
        @info "Composite DSL: Function call keyword args preserve routed display expressions"
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
        @test occursin("value = plus_capture.captured", sprint(show, StatefulAlgorithms.getplan(resolved)))

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
    end

    @testset "Function call keyword args accept semicolon same-name syntax" begin
        @info "Composite DSL: Function call keyword args accept semicolon same-name syntax"
        algo = @CompositeAlgorithm begin
            @state b = 1
            @state x = 2
            @state y = 3
            local result                                   # a final step sees what outlives the steps
            result = keyword_semicolon_dsl_test(a = b; x, y)
            @finally dsl_runtime_final_summary
        end

        resolved = resolve(algo)
        wrapper = StatefulAlgorithms.getalgo(resolved, 1)
        wrapper_summary = sprint(show, StatefulAlgorithms.getplan(resolved))
        @test occursin("a = _state_1.b", wrapper_summary)
        @test occursin("x = _state_1.x", wrapper_summary)
        @test occursin("y = _state_1.y", wrapper_summary)

        p = Process(resolved, repeat = 1)
        run(p)
        @test fetch(p) == (; result = 321)
        @test !haskey(StatefulAlgorithms.get_captured_returns(context(p)), :result)
        close(p)
    end

    @testset "An alias field route builds before a later statement of that alias" begin
        @info "Composite DSL: An alias field route builds before a later statement of that alias"
        algo = @Routine begin
            @alias dynamics = DSLHeldStateAlgo()
            DSLValueAlgo(value = dynamics.state)
            dynamics()
        end

        resolved = resolve(algo)
        sink = StatefulAlgorithms.getalgo(resolved, 1)
        sink_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        _, sharedvars = StatefulAlgorithms._resolved_wiring_by_target(resolved)
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
            DSLValueAlgo(value = model_state)
            dynamics()
        end

        resolved = resolve(algo)
        sink_key = StatefulAlgorithms.plan_child_namespace(resolved, 4)
        # Each child gets only its own routes, in its own slot of the plan's wiring
        # (function calls all share the `_captured_returns` namespace, so they are not grouped by name).
        child_routes(i) = StatefulAlgorithms.routes(StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved)))[i])
        @test length(child_routes(1)) == 1
        @test length(child_routes(2)) == 1
        @test StatefulAlgorithms.gettransform(only(child_routes(3))) !== nothing
        @test length(child_routes(4)) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :doubled)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :transformed)
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
        child_routes(i) = StatefulAlgorithms.routes(StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(nested_plan))[i])
        @test length(child_routes(1)) == 1
        @test length(child_routes(2)) == 1

        p = Process(resolved, repeat = 1)
        StatefulAlgorithms.run(p)
        ctx = fetch(p)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :doubled)
    end

    @testset "ProcessAlgorithm direct-call positional args accept alias field routes" begin
        @info "Composite DSL: ProcessAlgorithm direct-call positional args accept alias field routes"
        algo = @Routine begin
            @alias dynamics = DSLHeldStateAlgo()
            DSLPositionalCallAlgo(dynamics.state)
            dynamics()
        end

        resolved = resolve(algo)
        sink = StatefulAlgorithms.getalgo(resolved, 1)
        sink_key = StatefulAlgorithms.plan_child_namespace(resolved, 1)
        _, sharedvars = StatefulAlgorithms._resolved_wiring_by_target(resolved)
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
            DSLValueAlgo(value = state)
            dynamics()
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
            @include_if include_source (; produced, passthrough) = DSLSourceAlgo(seed = seed)
            DSLValueAlgo(value = seed)
        end

        resolved_skipped = resolve(skipped)
        @test length(StatefulAlgorithms.getalgos(resolved_skipped)) == 1
        @test StatefulAlgorithms.intervals(resolved_skipped) == (StatefulAlgorithms.Interval(1),)
        @test isnothing(StatefulAlgorithms.findkeyposition(resolved_skipped, :DSLSourceAlgo_1))

        p_skipped = Process(resolved_skipped, repeat = 1)
        StatefulAlgorithms.run(p_skipped)
        ctx_skipped = fetch(p_skipped)
        @test isempty(ctx_skipped[:DSLValueAlgo_1])

        include_source = true
        included = @CompositeAlgorithm begin
            @state seed = 3
            @include_if include_source (; produced, passthrough) = DSLSourceAlgo(seed = seed)
            DSLValueAlgo(value = produced)
        end

        resolved_included = resolve(included)
        @test length(StatefulAlgorithms.getalgos(resolved_included)) == 3   # with the capture of its return
        @test !isnothing(StatefulAlgorithms.findkeyposition(resolved_included, :DSLSourceAlgo_1))

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
            local produced, passthrough
            @include_if include_block begin
                (; produced, passthrough) = @interval 2 DSLSourceAlgo(seed = seed)
                @interval 2 DSLSinkAlgo(value = produced)
            end
            DSLValueAlgo(value = seed)
        end

        resolved_block = resolve(block_algo)
        @test length(StatefulAlgorithms.getalgos(resolved_block)) == 4
        # The capture of `DSLSourceAlgo`'s return runs on its schedule.
        @test StatefulAlgorithms.intervals(resolved_block) == (
            StatefulAlgorithms.Interval(2),
            StatefulAlgorithms.Interval(2),
            StatefulAlgorithms.Interval(2),
            StatefulAlgorithms.Interval(1),
        )

        include_block = false
        routine = @Routine begin
            @state produced = 5
            @include_if include_block @repeat 3 scaled_double_dsl_test(produced; scale = 3)
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
        @test !haskey(StatefulAlgorithms.get_captured_returns(ctx), :result)
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
        # A final step sees what outlives the steps (state, declared locals, inputs): here the declared local `result`.
        algo = @CompositeAlgorithm begin
            @state seed = 8
            local result
            result = keep_value_dsl_test(seed)
            @finally dsl_runtime_final_summary
        end

        @test algo isa StatefulAlgorithms.FinalizedAlgorithm
        resolved = resolve(algo)
        p = Process(resolved, repeat = 1)
        run(p)
        @test fetch(p) == (; result = 8)

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
                local result
                @repeat 2 begin
                    DSLValueAlgo(value = 1)
                    @finally dsl_final_summary
                end
            end
        end)
    end

    @testset "Function call outputs are runtime-only and visible to finalstep" begin
        @info "Composite DSL: Function call outputs are runtime-only and visible to finalstep"
        algo = @CompositeAlgorithm begin
            @state seed = 4
            local result                                   # a final step sees what outlives the steps
            result = keyword_value_identity_dsl_test(value = seed)
            @finally dsl_runtime_final_summary
        end

        p = Process(resolve(algo), repeat = 1)
        run(p)
        @test fetch(p) == (; result = 4)
        @test !haskey(StatefulAlgorithms.get_subcontexts(context(p)), :Callable_1)   # function calls have no persistent state
        @test !haskey(StatefulAlgorithms.get_captured_returns(context(p)), :result)

        close(p)
        @test fetch(p) == (; result = 4)
        @test !haskey(StatefulAlgorithms.get_captured_returns(context(p)), :result)
    end

    @testset "Function call literals: a quoted symbol and a captured Symbol value are values, not plan names" begin
        @info "Composite DSL: Function call literals are values, not plan names"
        marker = :done
        algo = @CompositeAlgorithm begin
            @state seed = 4
            local result                                   # a final step sees what outlives the steps
            result = literal_join_dsl_test(:start, seed, marker)
            @finally dsl_runtime_final_summary
        end

        p = Process(resolve(algo), repeat = 1)
        run(p)
        @test fetch(p) == (; result = "start4done")
        close(p)
    end

    @testset "An assignment on a schedule needs a declared name" begin
        @info "Composite DSL: An assignment on a schedule needs a declared name"
        produced = Ref(0)
        produce_dsl_test() = (produced[] += 1; Float64(produced[]))
        # Not declared: an error when the block is built, whatever reads it.
        for reader in (:(v = keep_value_dsl_test(y)), :(v = @every 3 keep_value_dsl_test(y)))
            err = try
                @eval @CompositeAlgorithm begin
                    @state seen = Any[]
                    y = @every 3 $produce_dsl_test()
                    $reader
                    seen = push_seen_dsl_test(seen, v)
                end
                nothing
            catch e
                e
            end
            @test err isa LoadError && occursin("Declare it first: `local y`", sprint(showerror, err.error))
        end

        # `local y` declares it without a value: reading it before its first assignment is an error.
        algo = @CompositeAlgorithm begin
            @state seen = Any[]
            local y
            y = @every 3 produce_dsl_test()
            seen = push_seen_dsl_test(seen, y)
        end
        produced[] = 0
        @test_throws UndefRefError run(InlineProcess(resolve(algo); repeats = 2))

        # Read on the same schedule, or after its first assignment: its last value.
        algo = @CompositeAlgorithm begin
            @state seen = Any[]
            local y
            y = @every 3 produce_dsl_test()
            seen = @every 3 push_seen_dsl_test(seen, y)
        end
        produced[] = 0
        p = Process(resolve(algo), repeat = 7); run(p)
        @test fetch(p)[:_state_1].seen == [1.0, 2.0]
        close(p)

        # `@every 1` runs in every step: no declaration needed.
        algo = @CompositeAlgorithm begin
            @state seen = Any[]
            y = @every 1 produce_dsl_test()
            seen = push_seen_dsl_test(seen, y)
        end
        produced[] = 0
        p = Process(resolve(algo), repeat = 2); run(p)
        @test fetch(p)[:_state_1].seen == [1.0, 2.0]
        close(p)
    end

    @testset "Declared locals: local x, local x::T; a declaration has no value" begin
        @info "Composite DSL: Declared locals"
        start = 10.0
        algo = @CompositeAlgorithm begin
            @state seen = Any[]
            local count::Int
            local offset
            count = length(seen)
            offset = keep_value_dsl_test(start)
            seen = push_four_dsl_test(seen, count, offset, 2.0f0, 1)
        end
        p = Process(resolve(algo), repeat = 3); run(p)
        @test fetch(p)[:_state_1].seen == [(0, 10.0, 2.0f0, 1), (1, 10.0, 2.0f0, 1), (2, 10.0, 2.0f0, 1)]
        close(p)

        # A value in a declaration is an error: a value kept between steps is state.
        for decl in (:(local x = 0.0), :(local x::Float32 = 2), :(local x = keep_value_dsl_test(1.0)))
            err = try
                @eval @CompositeAlgorithm begin
                    @state seen = Any[]
                    $decl
                    seen = push_seen_dsl_test(seen, x)
                end
                nothing
            catch e
                e
            end
            @test err isa LoadError && occursin("a local is declared without a value, `local x`", sprint(showerror, err.error))
        end

        # An algorithm statement reads a local through its input; assigning its return writes the local.
        algo = @CompositeAlgorithm begin
            @state seen = Any[]
            local x
            x = keep_value_dsl_test(0.0)
            x = DSLLocalBump(x)
            seen = push_seen_dsl_test(seen, x)
        end
        p = Process(resolve(algo), repeat = 3); run(p)
        @test fetch(p)[:_state_1].seen == [1.0, 1.0, 1.0]
        close(p)

        # Without `local`, `x = 0.0` assigns `x` every step, as in a Julia loop body.
        algo = @CompositeAlgorithm begin
            @state seen = Any[]
            total = 0.0
            total = plus_one_dsl_test(total)
            seen = push_seen_dsl_test(seen, total)
        end
        p = Process(resolve(algo), repeat = 3); run(p)
        @test fetch(p)[:_state_1].seen == [1.0, 1.0, 1.0]
        close(p)

        # A nested block reads and writes the locals of the blocks around it.
        algo = @CompositeAlgorithm begin
            @state seen = Any[]
            local total
            total = keep_value_dsl_test(0.0)
            @repeat 3 begin
                total = plus_one_dsl_test(total)
            end
            seen = push_seen_dsl_test(seen, total)
        end
        p = Process(resolve(algo), repeat = 2); run(p)
        @test fetch(p)[:_state_1].seen == [3.0, 3.0]
        close(p)

        # `x = y` with `y` a value of the block is an error: a bare name is not a step.
        err = try
            @eval @CompositeAlgorithm begin
                total = 0.0
                other = total
            end
            nothing
        catch e
            e
        end
        @test err isa LoadError && occursin("assigns the block's value `total` to `other`", sprint(showerror, err.error))

        # Declaring a name the block already has is an error.
        err = try
            @eval @CompositeAlgorithm begin
                @state x = 0.0
                local x
                x = keep_value_dsl_test(x)
            end
            nothing
        catch e
            e
        end
        @test err isa LoadError && occursin("is declared as a local, but the block already has a `x`", sprint(showerror, err.error))
    end

    @testset "Assigning an @input is an error when the block is built" begin
        @info "Composite DSL: Assigning an @input is an error"
        err = try
            @eval @CompositeAlgorithm begin
                @input x::Float64
                x = keep_value_dsl_test(1.0)
            end
            nothing
        catch e
            e
        end
        @test err isa LoadError && occursin("which is an `@input` of this block", sprint(showerror, err.error))
    end

    @testset "A header names the plan and declares its inputs" begin
        @info "Composite DSL: A header names the plan and declares its inputs"
        scaled_header_test(t, k) = t * k
        seen = Float64[]
        @CompositeAlgorithm header_comp(temperature::Float64, k = 2.0) begin
            y = scaled_header_test(temperature, k)
            push!(seen, y)
        end
        p = Process(header_comp; repeats = 2)
        run(p; temperature = 3.0)
        wait(p)
        @test seen == [6.0, 6.0]
        inputs = getfield(StatefulAlgorithms.inspect(header_comp; steps = false), :runtime_inputs)
        @test Dict(getfield.(inputs, :name) .=> getfield.(inputs, :required)) == Dict(:temperature => true, :k => false)

        seen_routine = Float64[]
        @Routine header_routine(t; k = 10.0) begin
            y = scaled_header_test(t, k)
            push!(seen_routine, y)
        end
        p = Process(header_routine; repeats = 1)
        run(p; t = 1.0)
        wait(p)
        @test seen_routine == [10.0]
    end

    @testset "A nested plan has no return value" begin
        @info "Composite DSL: A nested plan has no return value"
        plan_value_test() = 3
        plan_inc_test(x) = x + 1
        nested_plan = @Routine begin
            @state s = 0
            s = plan_inc_test(s)
        end
        plan_capture_error(f) = try
            f()
            nothing
        catch e
            e
        end

        # `x = nested()` with `nested` a plan, and `x = @repeat n begin … end`: errors when the block is built.
        err = plan_capture_error(() -> @eval @CompositeAlgorithm begin
            s = $nested_plan()
        end)
        @test err isa ErrorException
        @test occursin("a plan has no return value: declare `local s` before it and assign `s` inside the plan", sprint(showerror, err))

        err = plan_capture_error(() -> @eval @CompositeAlgorithm begin
            result = @repeat 2 begin
                result = plan_value_test()
            end
        end)
        @test err isa ErrorException
        @test occursin("a plan has no return value: declare `local result` before it and assign `result` inside the plan", sprint(showerror, err))

        # The explicit form: a local declared before the plan, assigned inside it.
        seen = Int[]
        run(@CompositeAlgorithm(begin
            local result
            @repeat 2 begin
                result = plan_value_test()
            end
            push!(seen, result)
        end); repeats = 2)
        @test seen == [3, 3]

        # A plan written elsewhere: read its state.
        seen = Int[]
        run(@CompositeAlgorithm(begin
            @context c = nested_plan()
            push!(seen, c.s)
        end); repeats = 2)
        @test seen == [1, 2]

        # The legacy macros keep binding the names by field.
        @test StatefulAlgorithms.getplan(resolve(@eval @CompositeAlgorithm_legacy begin
            s = $nested_plan()
        end)) isa Plan
    end

    @testset "A nested block reads the names of the blocks around it" begin
        @info "Composite DSL: A nested block reads the names of the blocks around it"
        one_nested_test() = 1.0
        addone_nested_test(x) = x + 1
        seen = Float64[]
        r = @Routine begin
            y = one_nested_test()
            @repeat 2 begin
                z = addone_nested_test(y)
                @repeat 2 begin
                    push!(seen, z)
                    push!(seen, y)
                end
            end
        end
        run(r; repeats = 1)
        @test seen == repeat([2.0, 1.0], 4)
    end

    @testset "An array literal is a step" begin
        @info "Composite DSL: An array literal is a step"
        bump_literal_test!(b) = (b[1] += 1; b)
        record_copy_test!(v, x) = (push!(v, copy(x)); nothing)
        seen = Vector{Float64}[]
        c = @CompositeAlgorithm begin
            buf = [0.0]
            bumped = bump_literal_test!(buf)
            record_copy_test!(seen, bumped)
        end
        a = resolve(c)
        run(a; repeats = 2)
        run(a; repeats = 2)
        @test seen == fill([1.0], 4)

        seen_local = Vector{Float64}[]
        c = @CompositeAlgorithm begin
            local acc
            acc = zeros(1)
            acc = bump_literal_test!(acc)
            record_copy_test!(seen_local, acc)
        end
        run(c; repeats = 3)
        @test seen_local == fill([1.0], 3)
    end

    @testset "Function call runtime output shape does not persist" begin
        @info "Composite DSL: Function call runtime output shape does not persist"
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
        @test !haskey(StatefulAlgorithms.get_captured_returns(fetched), :result)
        @test count[] == 2
        @test !haskey(StatefulAlgorithms.get_subcontexts(context(p)), :Callable_1)   # function calls have no persistent state
        @test !haskey(StatefulAlgorithms.get_captured_returns(context(p)), :result)
        close(p)
    end
end
