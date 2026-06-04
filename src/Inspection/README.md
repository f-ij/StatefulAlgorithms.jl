# Inspection

`Inspection` contains read-only tools for understanding a `LoopAlgorithm`
without reading its full source tree.

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
- which values were read during best-effort init and step analysis
- which analysis errors or missing values were encountered

This is not a performance profiler. It does not report time or allocations, and
it does not run the real loop. It uses the existing mock `ContextAnalyser`, so
the init/step sections are best-effort and depend on how directly algorithms
read from their context.

LoopAlgorithm-level runtime inputs are listed only when explicit runtime-input
metadata exists. Until the `@input` runtime feature is implemented, that section
will report no declared metadata.

