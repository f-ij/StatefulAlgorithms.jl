# TODO: parked non-core issues

Parked on 2026-09-25 while work focuses on core stability and speed. These issues are all outside
the core (entities/identity, registry/routing/context, loop algorithms, loop kernel, Process/InlineProcess).
Each was reproduced in the September 2026 code review unless marked *(unverified)*.

## HIGH PRIORITY: performance
- [ ] **Every `Process` built from a DSL block whose `@state` expression captures an outer value gets a brand-new algorithm type, so its loop is recompiled on every construction** (~55 ms and ~19 MiB for a trivial one-step process, ~0.5 s for the Gray-Scott one). Found while benchmarking `Demos/gray_scott` (2026-10-01, single thread). This is a *fixed cost per new Process*, not per iteration: 5 and 30000 iterations both took ~55 ms. Without a capture the type is stable and the second construction costs ~0.02 ms; the loop itself then costs ~7 ns per iteration, i.e. the framework is at ~zero overhead once compiled. Where the new type is minted is **not identified** (no `eval` in `src/CompositeDSL`), and it is not checked whether `main` behaves the same. A profile (`Profile.Allocs`) attributes the allocations to the compiler, running inside `makeloop!` (`src/Process.jl:336`) and `Locations.jl:324`. Verified repro:

  ```julia
  using StatefulAlgorithms
  @StepAlgorithm function Touch(U, steps); steps[] += 1; return (;); end
  function algo_of(captured, n)
      U0 = ones(Float32, n, n)
      return captured ?
          resolve(@CompositeAlgorithm begin
              @state sim begin; U = copy(U0); steps = Ref(0); end
              Touch(U, steps)
          end) :
          resolve(@CompositeAlgorithm begin
              @state sim begin; U = ones(Float32, n, n); steps = Ref(0); end
              Touch(U, steps)
          end)
  end
  for captured in (true, false)    # same call site, called twice
      println(captured, ": same type? ", typeof(algo_of(captured, 8)) === typeof(algo_of(captured, 8)))
  end
  # prints  true: same type? false   /   false: same type? true
  # then time `run(p); wait(p)` on fresh Process(algo; repeats = k) for captured = true: ~55 ms for any k
  ```
  Workaround: build arrays inside the `@state` expression (`U = ones(Float32, n, n)`), as `Demos/gray_scott` does.

## API readability
- [ ] `Interactive(:sim, :feed, :kill, :pairs, :period)` reads as five equal symbols: nothing shows that the first is the target subcontext and the rest are the fields to wrap. The call works fine; this is only how it looks. Candidates: `Interactive(:sim; fields = (:feed, :kill, :pairs, :period))`, or `Interactive(:sim => (:feed, :kill, :pairs, :period))`. First seen in `Demos/gray_scott/gray_scott_definitions.jl` (`gray_scott_process`).
- [ ] Step inputs and outputs are not symmetric in the DSL. Inputs are bound positionally, so the composer can use any name (`Relax(s, W, x, free, y)` binds the state field `free` to the step's parameter `beta`). Outputs are bound by name: `renamed = Make(seed); Take(renamed)` fails with `Key renamed not found in SubContext Make_1` when `Make` returns `(; made = ...)`; the left-hand name must equal the step's own return field. So a composition has to know the producer's internal field names. Wanted: let the composer name the connection (positional on the return tuple, or `x = Make(seed).made`), so steps stay reusable. Verified 2026-10-01 with a two-step `@Routine`.

## Process bookkeeping (touches the `Process` constructor)
- [ ] `src/ProcessList.jl:6`: the global `processlist` Dict is mutated without a lock, so concurrent `Process` construction (e.g. OnDemandWorkers under threaded execution) corrupts it.
- [ ] `src/ProcessList.jl:6`: bookkeeping never works: wrong key, `quit` and the finalizer never remove entries, `quitall` throws, and the Dict grows without bound.

## Process lifecycle
- [ ] `src/ProcessInteraction.jl:122`: `pause(p)` only raises flags and returns before the loop task has stopped, so callers that edit the context right after it race the last in-flight step. There is no synchronous pause (the Gray-Scott demo does `pause(p); wait(p)`).

## Process managers
- [ ] `src/Manager/Threaded.jl:239`: `SyncEvery(n)` is silently ignored by ThreadedWorkers and ChannelWorkers.
- [ ] `src/Manager/ProcessManager.jl:1529`: in PollingWorkers, one failed job wipes the slot context and loses earlier unsynced results.
- [ ] `src/Manager/Threaded.jl:50`: an exception thrown inside the error handler escapes the worker, losing jobs (Threaded) or deadlocking (Channel).
- [ ] `src/Manager/ProcessManager.jl:313`: a per-job lifetime from `providearguments` sticks to later jobs on the same slot.
- [ ] `src/Manager/ProcessManager.jl:1087`: `worker_init_data` is ignored for slots 2..n under the default CopyFirstWorker.
- [ ] `src/Manager/ProcessManager.jl:1344`: custom-worker recipes can't be portable, because polling requires `isdone` and threaded/channel reject it.
- [ ] `src/Manager/ProcessManager.jl:1560`: `SyncEvery(n; drain = true)` finalizes slots that are still running when the recipe uses `isdone`.
- [ ] `src/Manager/ProcessManager.jl:1763`: error semantics differ between execution modes, and an aborted polling run leaves in-flight jobs unsupervised.
- [ ] `src/Manager/Threaded.jl:67`: the per-job lifecycle is duplicated between the polling and threaded/channel paths.
- [ ] `src/Manager/ProcessManager.jl:1520`: a job value of `nothing` permanently wedges a polling slot.
- [ ] `src/Manager/ProcessManager.jl:574`: the background precompile calls an undefined `_try_precompile`, so it silently does nothing.
- [ ] `src/Manager/ProcessManager.jl:1739`: default polling (`poll_interval = 0.0`) busy-spins the caller task.
- [ ] `docs/src/user/threaded_process_managers.md:248`: there's no thread-safety contract saying which recipe callbacks may run concurrently.

## Tools and persistence
- [ ] `src/Tools.jl:184`: `est_remaining` throws when `progress == 0.0` (inline TODO).
- [ ] `src/Tools.jl:176`: `progress()` reports 0.0 once a completed process is closed *(unverified)*.

## Packaging and threaded composites
- [ ] `src/Packaging/StructDef.jl:19`: `Package` keeps a mutable schedule counter in the algorithm value, shared by every process using it.
- [ ] `src/Packaging/Step.jl:4`: children's same-named variables silently collapse into one package namespace.
- [ ] `src/Threaded/Step.jl:101`: `ThreadedCompositeAlgorithm` runs sequentially; the threaded path is unreachable from `run`/`Process` and broken.

## DSL front-end
- [ ] **HIGH (silent wrong results): using the same step type twice in one DSL block with different arguments makes every call use the LAST call's wiring, with no error or warning.** Verified (2026-10-01): `Probe(a)` then `Probe(b)` in one `@Routine` (state `a = 1.0`, `b = 2.0`): the first call received `2.0`. Cause: two `Probe()` values are equal, so they are one identity (documented in `docs/src/user/referencing_algorithms.md`, "reference by the same variable / `Unique`"), but nothing warns when the second use overwrites the first's routes. Workaround that works: `@alias a_use = Unique(Probe())` per use, with *keyword* routing (`a_use(v = a)`); positional routing through a `Unique` alias fails with "Too many positional DSL inputs ... Expected at most 0". Wanted: an error or warning at DSL expansion when one identity gets two different wirings, and positional names kept through `Unique`. Found while writing a free/nudged-phase learning routine (one `Relax` step used for both phases ran the free phase nudged).
- [ ] `src/CompositeDSL/Statements.jl:545`: `Algo()`-form ProcessState entries are registered as stepped children.
- [ ] `src/CompositeDSL/Statements.jl:480`: aliased ProcessState entries lose their alias key, so `alias.field` routes point at a missing key.
- [ ] `src/CompositeDSL/Statements.jl:391`: `@input` inside `@include_if` is ignored, but its name stays routable.
- [ ] `src/CompositeDSL/References.jl:11`: `@context` with a builder call is broken.
- [ ] `src/CompositeDSL/Invocations.jl:252`: captured non-isbits keyword values in function-call entries fail at construction.
- [ ] `src/CompositeDSL/Macros.jl:93`: unresolved route sources are silently dropped (typos, same-named globals, skipped `@include_if` producers).
- [ ] `src/CompositeDSL/StateAndRoutes.jl:173`: hygiene problem: escaped expressions contain `StatefulAlgorithms.`-qualified names, so they fail if the caller hasn't bound that module name.
- [ ] `src/CompositeDSL/Macros.jl:53`: the DSL re-implements the constructor parser, and the copy has drifted (no `RunIf`).

## DSL refactor (proposed 2026-10-06, nothing started; each item needs the owner's approval first)
- [ ] **Think hard about state in the DSL: who defines it, who owns it, and who may require it.** Open questions: must a block declare `@state` for every field its children use, or may children bring their own (today each nested block declares `@state x` and overlapping fields merge with a warning, resolved by `@bind`/`@merge`)? How do `@state` fields relate to `ProcessState` entries, `Init(...)`, `@input` and the declared `Local` loop locals from `exp/declared-locals`? Should required fields be declared once at the owning block, and what does a reusable child block promise about its own state? This decision shapes the `@state`/`@bind`/`@merge` syntax and the docs, so settle it before touching them.
- [ ] Write the DSL design-principles page (three evaluation times, what a bare identifier means, statement table, identity). A draft is in the session scratchpad (`Overview.draft.jl`); it replaces the `src/CompositeDSL/Overview.jl` header.
- [ ] Backend, no behaviour change, one commit per step: (1) a single `_dsl_is_macro(stmt, :name)` helper instead of ~25 hand-written `stmt.args[1] == Symbol("@...")` checks; (2) one `RouteInput` struct instead of four NamedTuple `kind`s; (3) one `_dsl_emit_entry` instead of four near-identical emit branches in `_dsl_build_statement`; (4) `@include_if` reuses the block walker. Reference: 854 tests pass on `main` before the refactor.
- [ ] Frontend, backward-compatible: deprecate `@every` in favour of `@interval`; give `@route`/`@replace` the same option syntax; fix the DSL front-end bugs above; decide whether to expose `Local` as `@local`.
- [ ] Docs: restructure `docs/src/user/composite_dsl.md` into tutorial, concepts and reference; shrink the macro docstrings to a pointer plus a syntax summary; expand the README; give `docs/src/index.md` a first-reader path; work through `DOCS_REVIEW_NOTES.md`.

## Inspection / ContextAnalyzer
- [ ] `src/ContextAnalyzer/ContextAnalyzer.jl:309`: the analyzer ignores routes and shares, so `inspect` lists routed and defaulted values as unresolved requests.

## Printing, legacy code, exports
- [ ] `src/Printing.jl:51`: `IndentIO` `show`/`print` overloads cause ~400 of the 463 method ambiguities, and `print(iio, "x")` itself throws; `IndentIO` is otherwise unused.
- [ ] `src/Trackers/AlgoBranch.jl:15`: legacy Trackers add global `::Any` fallbacks that hide MethodErrors.
- [ ] `src/Interactive/Interactive.jl:1`: the exported `isinteractive` shadows `Base.isinteractive` in user code.
- [ ] 11 exported names are undefined, and several exported helpers are broken.

## Tests, docs and repo hygiene
- [ ] `test/ContextExchangeTest.jl` has never been in `runtests.jl` and fails 3/40: manual `_step!(la, context)` builds a fresh cursor each call, so children with interval > 1 never run.
- [ ] `test/CompositeDSLTest.jl:404`: several DSL testsets only assert that nothing persisted, not the computed values.
- [ ] `test/ProcessManagerTest.jl:286`: threaded paths effectively run serially under the default `Pkg.test`; `ThreadedCompositeAlgorithm` is never executed.
- [ ] `test/InlineBenchmarkTest.jl:98`: a wall-clock timing assertion in the unit suite can fail on a busy machine.
- [ ] `docs/src/user/vars.md:27`: `Var(:name)` is still documented, but it can't work in lifetimes because nothing stores globals in a persistent context.
- [ ] `Project.toml`: Documenter is a runtime dependency, there are no `[compat]` bounds, and `[extras]`/`[targets]` are ignored because `test/Project.toml` exists.
- [ ] `test/Manifest.toml` disagrees with the root Manifest (JLD2 0.6.4 vs 0.5.15, Preferences 1.5.2 vs 1.4.3).
- [ ] No CI, so `docs/make.jl` deployment can never run.
- [ ] `LICENSE:8`: the text was corrupted by a global `sub`→`func` rename.
- [ ] About 17.5k lines of snapshots/, diagnostics/ and Profiling/ are tracked, plus `.DS_Store` and `LocalPreferences.toml`, with no `.gitignore`.
- [ ] `src/LoopAlgorithms/Showing.jl:210`: `Base.show(io, ::Type{LA}) where {Plan, LA<:LoopAlgorithm{Plan}}` throws `UndefVarError: Plan` ("not defined in static parameter matching") when printing a `LoopAlgorithm` type whose `Plan` parameter is not bound, e.g. a `UnionAll` inferred type; found when JET printed a report.
