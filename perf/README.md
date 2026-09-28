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
```

Warnings:

| Status | Meaning |
|---|---|
| `WRONG` | results differ from the hand-written loop |
| `TARGET` | ratio above the case's `target` (default 1.25) |
| `ALLOC` | allocates more per step than the case's `max_bytes` (default 0) |
| `REGRESS` | ratio worse than the baseline by more than 15% |

Ratios are compared rather than absolute times, so the baseline mostly carries
over between machines, but update it on the machine you compare on. Run it on a
quiet machine; other load mostly shows up as noise in the sub-nanosecond cases.

To add a case, add a `PerfCase` to `CASES` in `cases.jl` with a plan, a
hand-written equivalent, and a function extracting the same results from the
package context.
