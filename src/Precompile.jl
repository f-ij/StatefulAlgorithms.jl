struct _ProcessPrecompileCounter <: ProcessAlgorithm end
struct _ProcessPrecompileScaler <: ProcessAlgorithm end
struct _ProcessPrecompileSink <: ProcessAlgorithm end
struct _ProcessPrecompileNoop <: ProcessAlgorithm end
struct _ProcessPrecompileVectorPush <: ProcessAlgorithm end
struct _ProcessPrecompileSharedReader <: ProcessAlgorithm end

mutable struct _ProcessPrecompileFakeWorker
    idx::Int
    value::Int
    done::Bool
end

function init(::_ProcessPrecompileCounter, context)
    value = get(context, :value, 0)
    total = get(context, :total, 0)
    return (; value, total)
end

function step!(::_ProcessPrecompileCounter, context)
    value = context.value + 1
    return (; value, total = context.total + value)
end

function cleanup(::_ProcessPrecompileCounter, context)
    return (; total = context.total)
end

function init(::_ProcessPrecompileScaler, context)
    factor = get(context, :factor, 2)
    scaled = get(context, :scaled, 0)
    return (; factor, scaled)
end

function step!(::_ProcessPrecompileScaler, context)
    return (; scaled = context.scaled + context.factor)
end

function init(::_ProcessPrecompileSink, context)
    seen = get(context, :seen, 0.0)
    return (; seen)
end

function step!(::_ProcessPrecompileSink, context)
    return (; seen = context.seen + context.value)
end

init(::_ProcessPrecompileNoop, context) = (;)
step!(::_ProcessPrecompileNoop, context) = nothing
cleanup(::_ProcessPrecompileNoop, context) = (;)

function init(::_ProcessPrecompileVectorPush, context)
    values = Float64[]
    processsizehint!(values, context)
    return (; values, source = get(context, :source, 0.0))
end

function step!(::_ProcessPrecompileVectorPush, context)
    push!(context.values, context.source)
    return (;)
end

function init(::_ProcessPrecompileSharedReader, context)
    return (; total = 0.0)
end

function step!(::_ProcessPrecompileSharedReader, context)
    return (; total = context.total + context.source)
end

_process_precompile_add(x, y; bias = 0.0) = x + y + bias
_process_precompile_scale(x; scale = 1.0) = x * scale

@setup_workload begin
    @ProcessAlgorithm function _ProcessPrecompileSource(seed)
        produced = seed * 2.0
        passthrough = seed + 1.0
        return (; produced, passthrough)
    end

    @ProcessAlgorithm function _ProcessPrecompileManaged(
        x,
        @managed(total = start);
        gain = 1.0,
        @inputs((; start = 0.0))
    )
        total = total + x * gain
        return (; total)
    end

    @ProcessAlgorithm @config offset::Float64 = 1.0 begin
        function _ProcessPrecompileConfigured(
            x;
            gain = 1.0,
            @inputs((;))
        )
            y = x * gain + offset
            return (; y, offset)
        end
    end

    @ProcessAlgorithm function ProcessManagerPrecompileStep(
        @managed(
            x = Ref(0.0),
            y = Ref(0.0),
            params = Ref((w = 0.0, b = 0.0)),
            grad_w = Ref(0.0),
            grad_b = Ref(0.0),
            loss = Ref(0.0),
            nseen = Ref(0),
        );
        @inputs((;))
    )
        current = params[]
        prediction = current.w * x[] + current.b
        err = prediction - y[]
        grad_w[] += err * x[]
        grad_b[] += err
        loss[] += 0.5 * err^2
        nseen[] += 1
        return (;)
    end

    function _process_manager_precompile_context(worker)
        return context(worker)[ProcessManagerPrecompileStep]
    end

    function _process_manager_precompile_reset!(ctx)
        ctx.grad_w[] = 0.0
        ctx.grad_b[] = 0.0
        ctx.loss[] = 0.0
        ctx.nseen[] = 0
        return ctx
    end

    function _process_manager_precompile_flush!(state, worker_values)
        total_grad_w = 0.0
        total_grad_b = 0.0
        total_loss = 0.0
        total_seen = 0

        for worker in worker_values
            ctx = _process_manager_precompile_context(worker)
            total_grad_w += ctx.grad_w[]
            total_grad_b += ctx.grad_b[]
            total_loss += ctx.loss[]
            total_seen += ctx.nseen[]
            _process_manager_precompile_reset!(ctx)
        end

        if total_seen > 0
            params = state.params[]
            scale = inv(total_seen)
            next_params = (;
                w = params.w - state.lr * total_grad_w * scale,
                b = params.b - state.lr * total_grad_b * scale,
            )
            state.params[] = next_params
            state.total_loss[] = total_loss

            for worker in worker_values
                _process_manager_precompile_context(worker).params[] = next_params
            end
        end

        return state
    end

    @compile_workload begin
        source_state = init(_ProcessPrecompileSource(), (;))
        step!(_ProcessPrecompileSource(), (; seed = 2.0))

        managed_state = init(_ProcessPrecompileManaged(), (; start = 1.0))
        step!(_ProcessPrecompileManaged(), (; x = 2.0, total = managed_state.total, gain = 3.0))
        step!(_ProcessPrecompileManaged(), 2.0; _init = (; start = 1.0), gain = 3.0)

        managed_algo = CompositeAlgorithm(_ProcessPrecompileManaged)
        managed_specs = (
            Input(_ProcessPrecompileManaged, :start => 1.0),
            Override(_ProcessPrecompileManaged, :x => 2.0, :gain => 3.0),
        )
        resolved_managed_algo = resolve(managed_algo)
        resolve_process_inputs_overrides(resolved_managed_algo, managed_specs)
        initialized_managed_algo = StatefulAlgorithms.init(managed_algo, managed_specs...; lifetime = Repeat(1))
        getstoredcontext(initialized_managed_algo)

        managed_process = Process(managed_algo, managed_specs...; repeats = 1)
        run(managed_process)
        wait(managed_process)
        close(managed_process)

        initialized_managed_process = Process(initialized_managed_algo; repeats = 1)
        run(initialized_managed_process)
        wait(initialized_managed_process)
        close(initialized_managed_process)

        configured = _ProcessPrecompileConfigured(offset = 2.0)
        init(configured, (;))
        step!(configured, 2.0; gain = 3.0)
        step!(configured, (; x = 2.0, gain = 3.0))

        state_only = @state begin
            seed = 2.0
            bias = 1.0
        end
        init(state_only, (;))

        process = Process(_ProcessPrecompileCounter(); repeats = 2)
        run(process)
        wait(process)
        fetch(process)
        close(process)

        typed_process = Process(_ProcessPrecompileCounter; repeats = 1)
        run(typed_process)
        wait(typed_process)
        close(typed_process)

        input_process = Process(
            _ProcessPrecompileCounter,
            Input(_ProcessPrecompileCounter, :value => 3),
            Override(_ProcessPrecompileCounter, :total => 5);
            repeats = 1,
        )
        run(input_process)
        wait(input_process)
        close(input_process)

        inline_process = InlineProcess(
            _ProcessPrecompileManaged,
            Input(_ProcessPrecompileManaged, :start => 1.0),
            Override(_ProcessPrecompileManaged, :x => 1.0, :gain => 2.0);
            repeats = 2,
        )
        run(inline_process)
        run_nogen(inline_process)
        reset!(inline_process)

        inline_threaded = InlineProcess(_ProcessPrecompileCounter; repeats = 1, threaded = true)
        inline_threaded_task = run(inline_threaded)
        wait(inline_threaded_task)
        fetch(inline_threaded_task)

        inline_async = InlineProcess(_ProcessPrecompileCounter; repeats = 1, threaded = :async)
        inline_async_task = run(inline_async)
        wait(inline_async_task)
        fetch(inline_async_task)

        async_process = Process(_ProcessPrecompileScaler; repeats = 1)
        makeloop!(async_process; threaded = false)
        wait(async_process)
        close(async_process)

        until_process = Process(
            _ProcessPrecompileCounter();
            lifetime = RepeatOrUntil(_ -> true, 2, :globals),
        )
        run(until_process)
        wait(until_process)
        close(until_process)

        until_runtime_process = Process(
            _ProcessPrecompileCounter,
            Input(_ProcessPrecompileCounter, :value => 0);
            lifetime = Until(x -> x >= 2, Var(_ProcessPrecompileCounter, :value)),
        )
        run(until_runtime_process)
        wait(until_runtime_process)
        close(until_runtime_process)

        atleast_process = Process(
            _ProcessPrecompileCounter,
            Input(_ProcessPrecompileCounter, :value => 0);
            lifetime = AtLeast(x -> x >= 2, 1, Var(_ProcessPrecompileCounter, :value)),
        )
        run(atleast_process)
        wait(atleast_process)
        close(atleast_process)

        atleast_atmost_process = Process(
            _ProcessPrecompileCounter,
            Input(_ProcessPrecompileCounter, :value => 0);
            lifetime = AtLeastAtMost(x -> x >= 2, 1, 3, Var(_ProcessPrecompileCounter, :value)),
        )
        run(atleast_atmost_process)
        wait(atleast_atmost_process)
        close(atleast_atmost_process)

        base_process = Process(
            _ProcessPrecompileScaler,
            Input(_ProcessPrecompileScaler, :factor => 4);
            repeats = 1,
        )
        copyinputs(base_process)
        copyoverrides(base_process)
        copied_process = copyprocess(
            base_process,
            Input(_ProcessPrecompileScaler, :factor => 6);
        )
        run(copied_process)
        wait(copied_process)
        close(copied_process)
        close(base_process)

        routine = Routine(_ProcessPrecompileCounter, _ProcessPrecompileScaler, (2, 1))
        resolve(routine)
        keys(routine)
        propertynames(routine)
        initcontext(routine)
        routine_process = Process(routine; repeats = 1)
        run(routine_process)
        wait(routine_process)
        close(routine_process)

        composite = CompositeAlgorithm(
            :counter => _ProcessPrecompileCounter,
            :scaler => _ProcessPrecompileScaler,
            (1, 2),
            Route(_ProcessPrecompileCounter => _ProcessPrecompileScaler, :total => :factor),
        )
        resolved_composite = resolve(composite)
        keys(resolved_composite)
        propertynames(resolved_composite)
        initcontext(resolved_composite)
        initcontext(initcontext(resolved_composite), :counter)
        composite_process = Process(composite; repeats = 2)
        run(composite_process)
        wait(composite_process)
        close(composite_process)

        composite_inline = InlineProcess(composite; repeats = 2)
        run(composite_inline)
        run_nogen(composite_inline)
        loop(
            composite_inline,
            getalgo(composite_inline),
            context(composite_inline),
            lifetime(composite_inline),
            (;),
            Resuming{false}(),
            Generated(),
        )
        reset!(composite_inline)

        edited_composite = composite |>
            la -> addalgo(la, :extra => _ProcessPrecompileCounter, 1) |>
            la -> changeinterval(la, 1, 2) |>
            la -> changeintervals(la, (1, 1, 1)) |>
            la -> rename(la, :extra => :renamed_extra)
        keys(edited_composite)

        finalized = finalstep(
            CompositeAlgorithm(_ProcessPrecompileCounter, (1,)),
            context -> (; total = context[_ProcessPrecompileCounter].total),
        )
        finalized_process = Process(finalized; repeats = 1)
        run(finalized_process)
        wait(finalized_process)
        fetch(finalized_process)
        close(finalized_process)

        shared = CompositeAlgorithm(
            :writer => _ProcessPrecompileVectorPush,
            :reader => _ProcessPrecompileSharedReader,
            (1, 1),
            Share(_ProcessPrecompileVectorPush, _ProcessPrecompileSharedReader),
        )
        shared_process = Process(
            shared,
            Input(_ProcessPrecompileVectorPush, :source => 1.0);
            repeats = 2,
        )
        run(shared_process)
        wait(shared_process)
        close(shared_process)

        dsl_routine = @Routine begin
            _ProcessPrecompileCounter()
            _ProcessPrecompileScaler()
        end
        dsl_routine_process = Process(dsl_routine; repeats = 1)
        run(dsl_routine_process)
        wait(dsl_routine_process)
        close(dsl_routine_process)

        dsl_composite = @CompositeAlgorithm begin
            _ProcessPrecompileCounter()
            _ProcessPrecompileScaler()
        end
        dsl_composite_process = Process(dsl_composite; repeats = 1)
        run(dsl_composite_process)
        wait(dsl_composite_process)
        close(dsl_composite_process)

        dsl_composite_routed = @CompositeAlgorithm begin
            @state seed = 2.0
            @state bias = 1.0
            @alias src = _ProcessPrecompileSource
            produced, passthrough = src(seed)
            scaled = _process_precompile_scale(produced; scale = 3.0)
            combined = _process_precompile_add(scaled, passthrough; bias = bias)
            _ProcessPrecompileSink(value = combined)
        end
        resolved_dsl_composite_routed = resolve(dsl_composite_routed)
        initcontext(resolved_dsl_composite_routed)
        dsl_routed_process = Process(resolved_dsl_composite_routed; repeats = 2)
        run(dsl_routed_process)
        wait(dsl_routed_process)
        close(dsl_routed_process)

        dsl_interval_composite = @CompositeAlgorithm begin
            @interval 2 _ProcessPrecompileCounter()
            _ProcessPrecompileScaler()
        end
        resolved_dsl_interval_composite = resolve(dsl_interval_composite)
        initcontext(resolved_dsl_interval_composite)

        dsl_routine_with_state = @Routine begin
            @state precompile_routine_state begin
                seed = 1.0
            end
            _ProcessPrecompileSource(seed)
            _ProcessPrecompileSink(value = seed)
        end
        resolved_dsl_routine_with_state = resolve(dsl_routine_with_state)
        initcontext(resolved_dsl_routine_with_state)
        dsl_routine_state_process = Process(resolved_dsl_routine_with_state; repeats = 1)
        run(dsl_routine_state_process)
        wait(dsl_routine_state_process)
        close(dsl_routine_state_process)

        large_dsl_funcwrapper_routine = @Routine begin
            @state seed = 1.0
            @state bias = 0.25
            v1 = _process_precompile_scale(seed; scale = 1.01)
            v2 = _process_precompile_add(v1, bias; bias = 0.02)
            v3 = _process_precompile_scale(v2; scale = 1.03)
            v4 = _process_precompile_add(v3, v1; bias = 0.04)
            v5 = _process_precompile_scale(v4; scale = 1.05)
            v6 = _process_precompile_add(v5, v2; bias = 0.06)
            v7 = _process_precompile_scale(v6; scale = 1.07)
            v8 = _process_precompile_add(v7, v3; bias = 0.08)
            v9 = _process_precompile_scale(v8; scale = 1.09)
            v10 = _process_precompile_add(v9, v4; bias = 0.10)
            v11 = _process_precompile_add(@transform(x -> x + 0.11, v10), bias; bias = 0.11)
            v12 = _process_precompile_scale(v11; scale = 1.12)
            v13 = _process_precompile_add(v12, v6; bias = 0.13)
            v14 = _process_precompile_scale(v13; scale = 1.14)
            v15 = _process_precompile_add(v14, v8; bias = 0.15)
            v16 = _process_precompile_scale(v15; scale = 1.16)
            v17 = _process_precompile_add(v16, v10; bias = 0.17)
            v18 = _process_precompile_scale(v17; scale = 1.18)
            v19 = _process_precompile_add(v18, seed; bias = 0.19)
            v20 = _process_precompile_scale(v19; scale = 1.20)
        end
        resolved_large_dsl_funcwrapper_routine = resolve(large_dsl_funcwrapper_routine)
        initcontext(resolved_large_dsl_funcwrapper_routine)
        large_dsl_process = Process(resolved_large_dsl_funcwrapper_routine; repeats = 1)
        run(large_dsl_process)
        wait(large_dsl_process)
        close(large_dsl_process)

        fake_events = Int[]
        fake_recipe = (;
            makeworker = (idx, manager) -> _ProcessPrecompileFakeWorker(idx, 0, false),
            loadjob! = (slot, job, manager) -> begin
                slot.worker.value = job
                slot.worker.done = false
            end,
            start! = (slot, job, manager) -> (slot.worker.done = true),
            isdone = (slot, manager) -> slot.worker.done,
            finalize! = (slot, job, manager) -> nothing,
            afterjob! = (slot, job, manager) -> begin
                push!(fake_events, slot.worker.value)
                slot.worker.value = 0
            end,
            sync_to_state! = manager -> length(fake_events),
            close! = (slot, manager) -> (slot.worker.done = true),
        )
        fake_manager = ProcessManager(
            fake_recipe;
            nworkers = 2,
            sync_policy = SyncEvery(2; drain = true),
            job_type = Int,
            result_type = Nothing,
        )
        run!(fake_manager, 1:3)
        close(fake_manager)

        noflush_manager = ProcessManager(
            fake_recipe;
            nworkers = 1,
            sync_policy = NoSync(),
            job_type = Int,
            result_type = Nothing,
        )
        dispatch!(noflush_manager, 1)
        poll!(noflush_manager)
        drain!(noflush_manager)
        close(noflush_manager)

        no_drain_manager = ProcessManager(
            fake_recipe;
            nworkers = 1,
            sync_policy = SyncEvery(1; drain = false),
            job_type = Int,
            result_type = Nothing,
        )
        run!(no_drain_manager, 1:2)
        close(no_drain_manager)

        jobs = [(; x = 0.1, y = 0.2), (; x = 0.3, y = 0.4)]
        template = Process(ProcessManagerPrecompileStep; repeats = 1)
        recipe = (;
            initstate = config -> (;
                params = Ref(config.initial_params),
                lr = config.lr,
                total_loss = Ref(0.0),
            ),
            makeworker = (idx, manager) -> template,
            loadjob! = (slot, job, manager) -> begin
                ctx = _process_manager_precompile_context(slot.worker)
                ctx.x[] = job.x
                ctx.y[] = job.y
                ctx.params[] = manager.state.params[]
                resetworker!(slot)
            end,
            providearguments = (slot, job, manager) -> (;),
            sync_to_state! = manager -> _process_manager_precompile_flush!(manager.state, workers(manager)),
        )

        manager = ProcessManager(
            recipe;
            nworkers = 2,
            config = (; initial_params = (w = 0.0, b = 0.0), lr = 0.01),
            sync_policy = SyncAtEnd(),
            job_type = eltype(jobs),
            result_type = typeof(template),
        )
        run!(manager, jobs)

        reinit_worker = Process(
            _ProcessPrecompileCounter,
            Input(_ProcessPrecompileCounter, :value => 0);
            repeats = 1,
        )
        reinit_recipe = (;
            loadjob! = (slot, job, manager) -> reinitworker!(
                slot,
                Input(_ProcessPrecompileCounter, :value => job),
            ),
            afterjob! = (slot, job, manager) -> getticks(slot.worker),
        )
        reinit_manager = ProcessManager(
            reinit_recipe;
            workers = [reinit_worker],
            sync_policy = NoSync(),
            job_type = Int,
            result_type = typeof(reinit_worker),
        )
        run!(reinit_manager, 1:2)
        close(reinit_manager)
    end
end
