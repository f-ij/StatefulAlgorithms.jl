# Threaded Mode Results

Last local run:

```powershell
julia --project=. --threads=auto Profiling/manager/threaded_modes/actual_process_workloads.jl scale=1.0 samples=3 warmup=1
```

Environment:

- Julia threads: 8
- `Threads.maxthreadid()`: 16
- manager workers: 16
- BLAS threads: 1

## Actual `Process` Workloads

| Workload | Dynamic | Static | Greedy | Fastest |
| --- | ---: | ---: | ---: | --- |
| `process_linalg_equal` | 0.019923 s | 0.020497 s | 0.020335 s | `Dynamic()` by a small margin |
| `process_linalg_tail` | 0.082275 s | 0.082630 s | 0.027707 s | `Greedy()` |
| `process_trajectory_equal` | 0.128695 s | 0.128550 s | 0.126944 s | `Greedy()` by a small margin |
| `process_trajectory_tail` | 0.541954 s | 0.545487 s | 0.163853 s | `Greedy()` |
| `process_sort_tail` | 0.044281 s | 0.044182 s | 0.015976 s | `Greedy()` |

## Current Interpretation

For real `Process` workers, balanced work did not show a meaningful difference
between `Dynamic()`, `Static()`, and `Greedy()` on this machine. The winner moved
by small margins, so balanced workloads should keep the default `Dynamic()`
unless a local benchmark proves otherwise.

For long-tailed work, `Greedy()` was consistently better. The long-tail
trajectory workload was about 3.3x faster with `Greedy()` than `Dynamic()` or
`Static()`, and the sorting tail was about 2.8x faster.

`Static()` is still useful when a stable thread-to-slot mapping matters, but the
actual process workloads here did not show a speed advantage for it. Its main
performance risk is a long tail of expensive jobs landing on one thread.
