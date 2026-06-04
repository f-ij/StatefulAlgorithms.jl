using InteractiveUtils
using StatefulAlgorithms
using Profile

struct ManagerProfileAccumulator <: StatefulAlgorithms.ProcessAlgorithm end

"""
    StatefulAlgorithms.init(::ManagerProfileAccumulator, context)

Initialize a small mutable state used to measure `Process` worker lifecycle
churn under `ProcessManager`.
"""
function StatefulAlgorithms.init(::ManagerProfileAccumulator, context::C) where {C}
    value = get(context, :start, 0)
    return (; value = Ref(value), total = Ref(0))
end

"""
    StatefulAlgorithms.step!(::ManagerProfileAccumulator, context)

Accumulate one value so each process run does a small amount of real loop work.
"""
function StatefulAlgorithms.step!(::ManagerProfileAccumulator, context::C) where {C}
    context.total[] += context.value[]
    return (;)
end

"""
    manager_profile_process_context(worker)

Return the algorithm subcontext from the benchmark `Process` worker.
"""
function manager_profile_process_context(worker::P) where {P<:Process}
    subcontexts = StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.context(worker))
    names = filter(!=(:globals), fieldnames(typeof(subcontexts)))
    return getproperty(subcontexts, only(names))
end

"""
    process_churn_recipe(; inline = false)

Build a manager recipe that reuses one `Process` worker while changing its
mutable input state between jobs.
"""
function process_churn_recipe(; inline::Bool = false)
    prepare_callback = (slot, job, manager) -> begin
        local_context = manager_profile_process_context(slot.worker)
        local_context.value[] = job
        nothing
    end
    consume_callback = (slot, job, manager) -> begin
        local_context = manager_profile_process_context(slot.worker)
        local_context.total[]
    end

    if inline
        return (;
            prepare! = prepare_callback,
            start! = (slot, job, manager) -> runprocessinline!(slot.worker),
            isdone = (slot, manager) -> true,
            finalize! = (slot, job, manager) -> nothing,
            consume! = consume_callback,
        )
    end

    return (; prepare! = prepare_callback, consume! = consume_callback)
end

"""
    process_churn_manager(; inline = false)

Create the real-`Process` manager used to measure per-job task lifecycle churn.
"""
function process_churn_manager(; inline::Bool = false)
    worker = Process(ManagerProfileAccumulator(); repeats = 1)
    return ProcessManager(
        process_churn_recipe(; inline);
        workers = (worker,),
        flush_policy = NoFlush(),
        job_type = Int,
        result_type = inline ? Nothing : Any,
        error_type = Any,
    )
end

"""
    run_process_existing!(manager, n)

Run `n` jobs through an existing real-`Process` manager and return completed job
count.
"""
function run_process_existing!(manager::M, n::T) where {M<:ProcessManager, T<:Integer}
    run!(manager, 1:Int(n))
    return manager.completions
end

"""
    print_process_churn_profile(n)

Print inference, allocation, timing, and sampled profile data for manager-owned
real `Process` job churn.
"""
function print_process_churn_profile(n::T; inline::Bool = false, jet::Bool = false) where {T<:Integer}
    manager = process_churn_manager(; inline)
    run_process_existing!(manager, 10)

    println("manager type:")
    println(typeof(manager))

    if jet
        @eval using JET
        println()
        println("JET dispatch!/poll!/run! report:")
        Core.eval(@__MODULE__, :(JET.@report_opt dispatch!($manager, 1)))
        Core.eval(@__MODULE__, :(JET.@report_opt poll!($manager)))
        Core.eval(@__MODULE__, :(JET.@report_opt run!($manager, 1:2)))
    end

    run_process_existing!(manager, 20)
    GC.gc()
    println()
    println("allocations for $n jobs: ", @allocated run_process_existing!(manager, n))
    GC.gc()
    @time run_process_existing!(manager, n)

    Profile.clear()
    @profile for _ in 1:20
        run_process_existing!(manager, n)
    end
    println()
    Profile.print(format = :flat, sortedby = :count, maxdepth = 32, mincount = 1)
    return manager
end

n = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1_000
inline = length(ARGS) >= 2 && ARGS[2] == "inline"
jet = any(==("jet"), ARGS)
print_process_churn_profile(n; inline, jet)
