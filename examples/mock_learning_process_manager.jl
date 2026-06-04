using StatefulAlgorithms

@ProcessAlgorithm function MockLearningDynamics(
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

    # Fake local "learning signal". Workers only touch their own context buffers.
    grad_w[] += err * x[]
    grad_b[] += err
    loss[] += 0.5 * err^2
    nseen[] += 1

    return (;)
end

function zero_worker_buffers!(ctx)
    ctx.grad_w[] = 0.0
    ctx.grad_b[] = 0.0
    ctx.loss[] = 0.0
    ctx.nseen[] = 0
    return ctx
end

dataset = [
    (; x = -2.0, y = -3.8),
    (; x = -1.0, y = -1.9),
    (; x = 0.0, y = 0.2),
    (; x = 1.0, y = 2.1),
    (; x = 2.0, y = 4.2),
    (; x = 3.0, y = 6.1),
]

template = Process(MockLearningDynamics; repeats = 1)

recipe = (;
    initstate = config -> (;
        params = Ref(config.initial_params),
        lr = config.lr,
        epoch = Ref(0),
        history = NamedTuple[],
    ),

    makeworker = (idx, manager) -> copyprocess(template; context = deepcopy(template.context)),

    loadjob! = (slot, sample, manager) -> begin
        ctx = slot.worker.context[MockLearningDynamics]
        ctx.x[] = sample.x
        ctx.y[] = sample.y
        ctx.params[] = manager.state.params[]
        resetworker!(slot)
    end,

    sync_to_state! = manager -> begin
        total_grad_w = 0.0
        total_grad_b = 0.0
        total_loss = 0.0
        total_seen = 0

        for slot in slots(manager)
            ctx = slot.worker.context[MockLearningDynamics]
            total_grad_w += ctx.grad_w[]
            total_grad_b += ctx.grad_b[]
            total_loss += ctx.loss[]
            total_seen += ctx.nseen[]
            zero_worker_buffers!(ctx)
        end

        total_seen == 0 && return nothing

        params = manager.state.params[]
        scale = inv(total_seen)
        next_params = (;
            w = params.w - manager.state.lr * total_grad_w * scale,
            b = params.b - manager.state.lr * total_grad_b * scale,
        )
        manager.state.params[] = next_params
        manager.state.epoch[] += 1

        for slot in slots(manager)
            slot.worker.context[MockLearningDynamics].params[] = next_params
        end

        push!(manager.state.history, (;
            epoch = manager.state.epoch[],
            mean_loss = total_loss * scale,
            params = next_params,
        ))

        return nothing
    end,
)

manager = ProcessManager(
    recipe;
    nworkers = 3,
    config = (;
        initial_params = (w = 0.0, b = 0.0),
        lr = 0.08,
    ),
    sync_policy = SyncAtEnd(),
)

for _ in 1:8
    run!(manager, dataset)
end

println("Mock learning history:")
for row in manager.state.history
    println(
        "epoch=", row.epoch,
        " mean_loss=", round(row.mean_loss; digits = 4),
        " w=", round(row.params.w; digits = 4),
        " b=", round(row.params.b; digits = 4),
    )
end
