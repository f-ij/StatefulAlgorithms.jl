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
4. **`run(ip)` with `Unique` handles: was 64 bytes and +2.7 ns per call; now no allocation, +1.2 ns** (measured
   2026-11-06 against main `036b61ed`, 3 alternating rounds, minimum of 20 batches of 10^5 calls). The 64 bytes were a
   new registry `Ref` per run; fixed in `80ebb609` (no registry reaches the loop, `ProcessContext` holds its registry
   directly) and the `InlineProcess` field `loop_algo` (the plan without the map, made once; old #85). Now, two
   `Unique` counters: 6.3-6.5 ns per `run(ip)` here against 5.1-5.4 ns on main; without `Unique` handles 4.6-4.7 here
   against 4.9 ns on main. The perf suite (loop time per step) is unchanged in all 26 rows. Probably left: the registry
   is stored by value in the process's context and put on the result (`with_plan_registry`), and its entries hold a
   `Vector` (`multipliers`) and a `Dict` (`dynamic_lookup`), so every store has GC write barriers. Making the registry
   plain data (those two moved out) is the TODO "Does a running loop need the registry?"; not measured.
   Per step (2026-11-06, long runs, minimum over rounds, main against this branch): no case is slower here. Two `Unique`
   counters 0.45 ns (both); `Process` 0.51-0.57 ns (both); a lifetime reading a `Unique`'s `Var`: `InlineProcess`
   0.48-0.50 -> 0.46 ns, `Process` 1.65-1.68 -> 0.63-0.65 ns; a `RunIf` on a type's `Var` 0.25-0.33 -> 0.24 ns; a
   routine child's lifetime on a type's `Var` 0.71-0.74 -> 0.66-0.67 ns (both sides also show 1.3-1.8 ns runs, likely
   the slower cores). A `RunIf` or routine-child lifetime on a `Unique` handle's `Var` errors on main ("Wiring references
   Var subcontext not found in registry") and runs here (0.24 ns, 0.67 ns).
5. **The InteractiveIsing checks cannot run against main or this branch.** InteractiveIsing (all branches, newest
   `landau-ginzburg-relax` 2026-11-03) calls `StatefulAlgorithms.context`, renamed `getcontext` on main, so it does not
   load with main's SA either. The 3D throughput, phi and II test checks need InteractiveIsing ported to the current SA
   API first.
6. **Two broken process functions, also on main** (found by the docs review, 2026-11-06; not fixed):
   - `quitall()` (src/Processes/Process/Lifecycle.jl) calls `quit` on each `processlist` value, which is a `WeakRef`, not
     the process (`quit` has no `WeakRef` method); it should use `.value` and skip collected entries.
   - `cleanup(p::AbstractProcess)` (src/Processes/Context.jl) calls `tasklifetime(p)`, which is defined nowhere.
