# ProcessManager Threaded Mode Profiling

This folder compares the three `ProcessManager` threaded schedules:

- `Dynamic()`
- `Static()`
- `Greedy()`

Run from the repository root:

```powershell
julia --project=. --threads=auto Profiling/manager/threaded_modes/compare_threaded_modes.jl
```

For quicker iteration:

```powershell
julia --project=. --threads=auto Profiling/manager/threaded_modes/compare_threaded_modes.jl scale=0.25 samples=3
julia --project=. --threads=auto Profiling/manager/threaded_modes/actual_process_workloads.jl scale=0.25 samples=3
```

To print sampled profile data for every workload and mode:

```powershell
julia --project=. --threads=auto Profiling/manager/threaded_modes/compare_threaded_modes.jl profile profile_repeats=10
```

## What It Measures

`compare_threaded_modes.jl` uses a small fake worker recipe. The worker executes
inside the manager slot lifecycle, so the measurements focus on manager-level
thread scheduling, slot borrowing, and workload balance. They intentionally do
not include `Process` task creation because `runthreaded!` runs default
`Process` workers inline.

`actual_process_workloads.jl` uses reusable real `Process` workers. It measures
the threaded manager schedules while running matrix-vector transforms,
trajectory integration, and allocation-heavy sorting inside process `step!`
methods. BLAS is pinned to one thread so the comparison is between manager
schedules, not nested BLAS threads.

The workloads are:

- `tiny_equal`: many tiny equal-cost jobs, mostly scheduler overhead.
- `cpu_equal`: equal CPU-heavy jobs, where static partitioning should be strong.
- `cpu_skewed`: mostly short CPU jobs with a long tail of expensive jobs.
- `allocation_mixed`: jobs that allocate per run, with mixed allocation sizes.
- `sleep_skewed`: uneven yielding/blocking jobs, useful as an I/O-like proxy.

The actual-process workloads are:

- `process_linalg_equal`: equal-cost matrix-vector transform jobs.
- `process_linalg_tail`: matrix-vector jobs with a long expensive tail.
- `process_trajectory_equal`: equal-cost nonlinear trajectory integration.
- `process_trajectory_tail`: trajectory integration with a long expensive tail.
- `process_sort_tail`: allocation-heavy sorting jobs with larger tail jobs.

## Reading Results

Use the fastest schedule per workload as a starting point, not as a universal
default. Re-run with job counts and work sizes close to your application.

Expected patterns:

- `Static()` is often best for equal CPU work because it has no slot pool
  channel traffic and each thread owns a stable slot.
- `Dynamic()` is the default because it handles uneven jobs while still bounding
  active work to manager slots.
- `Greedy()` can help when job costs are uneven enough that Julia's greedy
  scheduler improves balance. It can lose on tiny jobs because scheduling
  overhead dominates.

`Static()` requires at least `Threads.maxthreadid()` manager slots. The script
uses that slot count for all modes so the comparison is fair.
