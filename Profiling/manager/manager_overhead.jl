using InteractiveUtils
using StatefulAlgorithms
using Profile

mutable struct ManagerProfileWorker
    count::Int
    done::Bool
end

"""
    manager_profile_recipe()

Build a synchronous fake-worker recipe that exercises manager scheduling without
allocating worker tasks or result buffers.
"""
function manager_profile_recipe()
    return (;
        makeworker = (idx, manager) -> ManagerProfileWorker(0, false),
        prepare! = (slot, job, manager) -> (slot.worker.count += job; nothing),
        start! = (slot, job, manager) -> (slot.worker.done = true; nothing),
        isdone = (slot, manager) -> slot.worker.done,
        finalize! = (slot, job, manager) -> (slot.worker.done = false; nothing),
    )
end

"""
    manager_profile_manager(nworkers)

Create a typed manager for scheduler-only profiling.
"""
function manager_profile_manager(nworkers::T) where {T<:Integer}
    return ProcessManager(
        manager_profile_recipe();
        nworkers,
        flush_policy = NoFlush(),
        job_type = Int,
        result_type = Nothing,
        error_type = Any,
    )
end

"""
    run_existing!(manager, n)

Run `n` integer jobs through an already-constructed manager and return completed
job count.
"""
function run_existing!(manager::M, n::T) where {M<:ProcessManager, T<:Integer}
    run!(manager, 1:Int(n))
    return manager.completions
end

"""
    print_manager_profile(nworkers, n)

Print inference, allocation, timing, and sampled profile data for the fake
worker scheduler path.
"""
function print_manager_profile(nworkers::T, n::T; jet::Bool = false) where {T<:Integer}
    manager = manager_profile_manager(nworkers)
    run_existing!(manager, 10)

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

    run_existing!(manager, 100)
    GC.gc()
    println()
    println("allocations for $n jobs: ", @allocated run_existing!(manager, n))
    GC.gc()
    @time run_existing!(manager, n)

    Profile.clear()
    @profile for _ in 1:200
        run_existing!(manager, n)
    end
    println()
    Profile.print(format = :flat, sortedby = :count, maxdepth = 24, mincount = 1)
    return manager
end

nworkers = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8
n = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 100_000
jet = any(==("jet"), ARGS)
print_manager_profile(nworkers, n; jet)
