using StatefulAlgorithms

struct ManagedAccumulator <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::ManagedAccumulator, context)
    return (; value = Ref(0), delta = Ref(1), local_buffer = Int[])
end

function StatefulAlgorithms.step!(::ManagedAccumulator, context)
    push!(context.local_buffer, context.value[])
    context.value[] += context.delta[]
    return (;)
end

template = Process(ManagedAccumulator; repeats = 3)
external_buffer = Int[]

recipe = (;
    makeworker = (idx, manager) -> copyprocess(template; context = deepcopy(template.context)),

    loadjob! = (slot, job, manager) -> begin
        ctx = slot.worker.context[ManagedAccumulator]
        ctx.value[] = job.start
        ctx.delta[] = job.delta
        resetworker!(slot)
    end,

    sync_to_state! = manager -> begin
        for slot in slots(manager)
            ctx = slot.worker.context[ManagedAccumulator]
            append!(external_buffer, ctx.local_buffer)
            empty!(ctx.local_buffer)
        end
    end,
)

jobs = [
    (; start = 1, delta = 2),
    (; start = 10, delta = 3),
    (; start = 100, delta = 10),
]

manager = ProcessManager(recipe; nworkers = 2, sync_policy = SyncAtEnd())
run!(manager, jobs)

println("Flushed values: ", external_buffer)
