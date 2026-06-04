# ProcessManager Profiling

Run these scripts from the repository root with:

```powershell
julia --project=. Profiling/manager/manager_overhead.jl
julia --project=. Profiling/manager/process_churn.jl
julia --project=. Profiling/manager/process_churn.jl 1000 inline
julia --project=. Profiling/manager/process_churn.jl 1000 inline jet
julia --project=. --threads=auto Profiling/manager/threaded_modes/compare_threaded_modes.jl
julia --project=. --threads=auto Profiling/manager/threaded_modes/actual_process_workloads.jl
```

`manager_overhead.jl` isolates scheduler overhead with a synchronous fake
worker. It is useful for checking type stability, allocations, and slot-search
costs without including `Process` task creation.

`process_churn.jl` uses a real `Process` worker and reports the per-job
allocation cost of the default manager `Process` protocol. That path includes
task creation, wait/fetch/close, runtime context merging, and cleanup.

Passing `inline` as the second argument switches the recipe to
`runprocessinline!`, which runs the `Process` loop synchronously and avoids
per-job task creation when manager-level concurrency is not needed.

Passing `jet` as the last argument adds `JET.@report_opt` checks. Keep it off
for timing runs because it can add compilation noise to short benchmarks.

`threaded_modes/compare_threaded_modes.jl` compares the `Dynamic()`, `Static()`,
and `Greedy()` threaded manager schedules across balanced CPU, skewed CPU,
allocation-heavy, and yielding workloads. Use it to choose a schedule for a
specific job distribution instead of assuming one schedule is always fastest.

`threaded_modes/actual_process_workloads.jl` repeats the schedule comparison
with real reusable `Process` workers doing matrix-vector, trajectory, and
sorting work inside `step!`.
