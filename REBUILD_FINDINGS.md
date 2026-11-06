# Rebuild findings: things to look at at the end

Started 2026-11-06 during the rebuild of `refactor/plan-compiles` (REBUILD_PLAN_COMPILES.md). Things that looked
suspicious while porting; nothing here is acted on yet unless it says so.

1. **`9d5c7936` is the commit that creates `replace_unique_ids` itself.** The owner moved it from
   `refactor/monolithic-resolve` to this branch (row #107, 2026-11-06). It adds
   `src/Identifiable/UniquePlanId/ReplaceIds.jl` (the monolithic function) and, with it, changes that are not the
   function: `rebuild_with_fields` hook methods for `IdentifiableAlgo`/`Route`/`Share`/`Redirect` (replacing the tuple
   hook `list_field_derived_params`), the modes renamed (RewriteModes.jl -> ReplaceModes.jl), `number_by_keymap` built
   from the new locations, `WithWiring{C, W}` typed and `@nospecializeinfer` plan-constructor helpers. The other three
   commits on monolithic-resolve (`7d958cb7`, `0c063e9c`, `ee3660be`) only change ReplaceIds.jl, so they stay there,
   but they build on `9d5c7936`: monolithic-resolve has to be rebuilt on top of this branch's #107. Decide whether the
   whole of `9d5c7936` belongs here or only its non-function parts.
2. **Main's `schedule_processmanager_precompile!` called an undefined `_try_precompile`** (no definition anywhere on
   main). It ran on a spawned task, so the error never surfaced and no manager method was precompiled. Replaced in the
   port of #31-#38 by `precompile_interface(::ProcessManager)` (plain `precompile` calls, no global set of seen types),
   as the old branch did in #36.
3. **Rows held for `refactor/partitions`.** #83 and #84 (`Partition{kind, name}`), #100 (`Var` as an unresolved
   `VarLocation`), #103 (SCRef -> nsref/partref) and #106 have reworked twins on `refactor/partitions`, which is not in
   main (26 commits ahead on 2026-11-06). Porting the old forms here would duplicate that work and clash with it, so
   these rows stay open, together with the rows that build on them (#101 resolved locations without a matcher, #102
   `resolve_var(s)`, #105 if it needs them). Port them once partitions is in main. The handoff said to ask at the first
   twin; the owner said to finish without questions and note such things here.
4. **`run(ip)` allocates 64 bytes per call when the plan has `Unique` handles** (measured 2026-11-06, main `036b61ed` against
   this branch `f5a66237`, 3 alternating rounds). A short `run(ip)` (two `Unique` counters, 1 or 10 steps) costs 7.6-7.9 ns
   per call here against 5.0-5.1 ns on main; without `Unique` handles both are 4.9 ns and allocate nothing. Cause:
   `prepare_for_loop(::InlineProcess)` strips the map with `strip_keymap_typed`, which builds a new registry `Ref` for the
   loop's context on every run. The per-step loop time is unchanged (perf suite, all 26 rows within noise). Possible
   fixes, not done: the loop's context needs no registry at all (a `reg::Nothing` loop context), or the stripped
   registry `Ref` is made once with the process's context and reused (it holds no map, so it is not a map in the
   process).
5. **The InteractiveIsing checks cannot run against main or this branch.** InteractiveIsing (all branches, newest
   `landau-ginzburg-relax` 2026-11-03) calls `StatefulAlgorithms.context`, renamed `getcontext` on main, so it does not
   load with main's SA either. The 3D throughput, phi and II test checks need InteractiveIsing ported to the current SA
   API first.
