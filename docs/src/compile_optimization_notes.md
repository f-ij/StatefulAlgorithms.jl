# Compile Optimization Notes

Potential next targets, in the order they should be investigated:

1. Reduce the remaining generated merge/context code.
   The latest profile still shows `merge_into_subcontext_*`,
   `merge_into_subcontexts`, generated `ProcessContext` construction, and
   generated `SubContextView` `getproperty` in the first-run compile path. The
   single-name lookup already removed the biggest `get_all_locations` cost; the
   next step should be smaller emitted expressions, not more background tasks.

2. Check whether `get_all_locations` is still needed in normal non-error paths.
   It should now be mostly property enumeration, explicit `keys`/`propertynames`,
   and error reporting. If profiles show it from normal execution again, trace
   the exact caller before adding a cache.

3. Check first-step and steady-step duplication.
   Repeat loops compile an unstable first step and a stable steady loop. For
   algorithms whose context type cannot grow, there may be a way to skip or
   shrink the unstable generated path.

4. Isolate context init merge cost.
   Lifecycle `init` now resolves `Init`/`Override` specs and stores them on the
   initialized loop algorithm. The remaining cost is probably applying named
   specs through generated context merge/init code. Benchmark `init(la)` with
   and without specs separately.

5. Cache resolved algorithm metadata by concrete loop algorithm type.
   Registry setup, flat funcs/states/multipliers, and share/route resolution are
   mostly type-structural. This must account for mutable algorithm instances and
   options that are value-dependent.

6. Split generated step compilation only where the semantic boundary is clear.
   Avoid random helper churn. Candidate boundaries are route lookup, context view
   access, and merge planning. The goal is to let shared structural parts compile
   once while keeping the final concrete setter fast.

7. Benchmark `copyprocess` and context copy cost separately.
   Learning workloads copy template contexts often. Measure whether
   `deepcopy(context)` or fresh structural init is more expensive for realistic
   contexts.

8. Keep `Process` first-entry context concrete but resumed context broad.
   The stored LoopAlgorithm context is already concrete and should remain the
   first-run source. `Process.runtime_context` is deliberately
   `Union{Nothing, ProcessContext}` for resumed/replaced contexts; do not add a
   `Process{F,C}` parameter again unless a new profile shows a real win.

9. Keep empty tuple paths specialized.
   Empty inputs, overrides, options, shares, and routes are common and should
   avoid generic filtering/merging.

10. Keep the compile benchmark suite current.
    Report package load separately from stage timings, and keep cold and warm
    stage measurements separate.

11. Revisit background precompile only from values close to first use.
    Process-constructor loop precompile has been useful enough to keep.
    LoopAlgorithm-constructor metadata precompile was too early and contended
    with construction/input resolution. Any new background precompile should be
    measured against total construct-to-first-run time, not construction alone.

12. Avoid precompile hooks that only move work earlier.
    Constructor loop precompile should target exact first-run signatures.
    Resolve-time precompile and broad metadata precompile have both been tested
    and made immediate TTFP worse. The next useful precompile work is probably
    reducing the amount of generated user-algorithm-specific code, not launching
    more tasks earlier.
