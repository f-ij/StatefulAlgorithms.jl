# Inspection

`Inspection` contains structural diagnostics for understanding a
`LoopAlgorithm` without reading its full source tree.

The public entry point is:

```julia
report = inspect(loop_algorithm)
show(report)
```

The report is intended to answer composition questions:

- which named contexts are registered
- which entries are persistent state versus process algorithms
- which contexts are shared
- which routed variables cross context boundaries
- which unresolved values were requested during best-effort init and step analysis
- which analysis errors or missing values were encountered

This is not a performance profiler. It does not report time or allocations, and
it does not run the real loop. It uses the existing mock `ContextAnalyser`, so
the init/step sections are best-effort and depend on how directly algorithms
read from their context. The analyzer invokes user `init` and `step!` hooks with
recording views; hooks that mutate captured objects or perform external side
effects can still do so.

LoopAlgorithm-level runtime inputs are listed when the composition declares
them with DSL `@input`. If there are no declarations, that section reports no
declared metadata.
