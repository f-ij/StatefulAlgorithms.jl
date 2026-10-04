# Performance regression suite

Not part of the tests. Each case in `cases.jl` pairs a package plan with a
hand-written Julia loop computing exactly the same results. `run.jl` checks the
results match, then times both alternately in the same process (minimum over 7
rounds) and reports the ratio package / hand-written, plus bytes allocated per step.

```bash
julia --project=perf perf/run.jl                     # compare against baseline.toml
julia --project=perf perf/run.jl --only Routine      # only cases whose name contains "Routine"
julia --project=perf perf/run.jl --update-baseline   # store this run as the new baseline
julia --project=perf perf/run.jl --strict            # exit 1 on any warning (for hooks/CI)
julia --project=perf perf/run.jl --runtime-only      # skip compile times
julia --project=perf perf/run.jl --compile-only      # only compile times
```

Compile times are measured in fresh processes by `compile.jl` (minimum over 3
processes, 2 for package precompile): package precompile, `using`, the first run
of a plan under `InlineProcess` and `Process`, and reconfiguring the plan (one
interval changed; for the DSL case, rebuilding the same block). Plans covered:
composites, nested composites, a wide composite, three routine shapes and a DSL
block. These are absolute times, so they only warn (`SLOWER`) when more than 25%
**and** more than 0.1 s worse than the baseline.

Warnings:

| Status | Meaning |
|---|---|
| `WRONG` | results differ from the hand-written loop |
| `TARGET` | ratio above the case's `target` (default 1.25) |
| `ALLOC` | allocates more per step than the case's `max_bytes` (default 0) |
| `REGRESS` | ratio worse than the baseline by more than 15% |
| `SLOWER` | a compile time worse than the baseline by more than 25% and 0.1 s |

Ratios are compared rather than absolute times, so the baseline mostly carries
over between machines, but update it on the machine you compare on. Run it on a
quiet machine; other load mostly shows up as noise in the sub-nanosecond cases.

To add a case, add a `PerfCase` to `CASES` in `cases.jl` with a plan, a
hand-written equivalent, and a function extracting the same results from the
package context.
