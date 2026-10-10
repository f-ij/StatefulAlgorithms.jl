# TODO: parked non-core issues

Parked on 2026-09-25 while work focuses on core stability and speed. These issues are all outside
the core (entities/identity, registry/routing/context, loop algorithms, loop kernel, Process/InlineProcess).
Each was reproduced in the September 2026 code review unless marked *(unverified)*.

## Core: to look at
- [ ] **What a run gives back** (survey 2026-10-16, on `refactor/no-first-step`). Today the stored context (`context(p)`) is persistent only, but `run(ip)`/`fetch(p)`/`lastresult` return the persistent context with the runtime partitions left at the end (`_inputs`, `_declared_locals`) merged in (`visible_context`, name to be changed), while `run(la)` returns persistent state only; a paused `context(p)` also holds `_inputs`/`_declared_locals` (resume reads them back). Who reads runtime values from it: InteractiveIsing and IsingLearning never (only state fields, `context[logger]`, `[:_state]`); SA tests only `get_declared_locals(run(...))` (`test/CallableTest.jl:21`, `test/LocalTest.jl`) and final steps that read a `local` (`test/CompositeDSLTest.jl:69`, `test/CallableTest.jl:96,131`); no final function uses the second `(cleaned_context, runtime_context)` argument; routine stop conditions may read locals (documented, untested). Proposal: (1) `run`/`fetch`/`lastresult` without a final step return the persistent context, as `context(p)` and `run(la)`; (2) a final step keeps seeing state + declared locals + inputs, the one way to get a `local` out of a run (`@finally ctx -> ctx.result`); (3) drop the final function's second argument; (4) run and routine stop conditions unchanged; (5) a paused process keeps its inputs/declared locals in a `Process` field next to the loop cursor, so `context(p)` is always persistent only. Touches the tests above, the `!haskey(get_captured_returns(fetch(...)))` checks (then true by construction) and IL `examples/learning.jl:30` (feeds `run(p)` into `initcontext`).
- [ ] **Runtime context with mixed declared locals as a loop value** *(unmeasured)*. On `refactor/no-first-step` the runtime context keeps one type across steps and is carried from step to step. When a declared local holds pointers and plain data together (e.g. a struct with a `Vector` and a `Float64`), the runtime context is such a mixed struct, which Julia keeps in a stack slot and copies whole every step (as for the persistent context, see "Hot loop, context copy"). Measure on a plan with such a `local`: `llvm.memcpy` of the runtime context in the compiled loop, and loop time against the same plan with the value in a `@state`.
- [ ] **Unneeded `Val(...)` arguments.** Many internal helpers take a name as `Val(name)` (e.g. `_runtime_get_var(ctx, Val(sub), Val(var))` on `refactor/dsl-locals-rebased`). A `Val` is only needed where a method dispatches on the name or where the name would otherwise be a runtime value. Where the name is already a compile-time constant at every call site (a static parameter or a literal in generated code), a plain `Symbol` infers just as well (`getproperty(nt, s)` with `s` a static parameter infers the field type; `getfield` does too, without relying on constant propagation). Go through the `Val` arguments and drop the ones that do nothing, and the one-line wrappers that exist only to carry them. Noted 2026-10-15.
- [ ] **`Documenter` is a package dependency but `src/` never loads it.** It is listed under `[deps]` in Project.toml, so every user of SA installs it; it does not affect load or compile time (only loaded packages cost anything). It belongs in the docs project (`docs/Project.toml`). Noted 2026-10-13.
- [ ] **Process: per-repeat tick counting as an option at construction.** `tick!(p::Process)` increments `p.tickidx` on every routine repeat, for monitoring (`getticks`). Repeats can run long, so a counter that moves during them is useful for interactive progress, but writing it to memory on every repeat costs time in tight loops (a store and a reload of the same field per repeat; see the exp/inline-scopes notes, 2026-10-13). Make it a choice when creating a `Process` (a static type parameter, so the check compiles away): count every repeat, or only once per step. Noted 2026-10-13.
- [ ] **Does a running loop need the registry?** Every `ProcessContext` carries `reg::Base.RefValue{NameSpaceRegistry}`, a pointer: the registry is not plain data because each `RegistryTypeEntry` keeps construction-time data behind pointers (`multipliers::Vector{Float64}`, `dynamic_lookup::Dict{Any,Int}`). So every context written into a process costs a GC write barrier, and contexts are GC-tracked. Check what the loop reads from the registry at run time; if nothing (or only what its type already says), give the loop's contexts no registry (e.g. `reg::Nothing` while looping, the real one put back after), or make the registry plain data by moving `multipliers`/`dynamic_lookup` into construction-time structures. Noted 2026-10-13 (found while investigating exp/inline-scopes; it is not the cause of the slowdowns there).
- [ ] **DSL: `local y = expr` with Julia's meaning.** On `refactor/dsl-locals-rebased` a declaration has no value (`local y`; `local y = 0.0` is an error, a starting value is `@state`). In Julia, `local y = expr` makes a new `y` from that point on: it does not reuse the old variable, so its type may differ from an earlier `y`. Supporting that would give the statement its own slot (possibly of another type) instead of writing the declared one. Not urgent; noted 2026-10-12.
- [ ] **Finalizers (`@finally`, `finalstep`): decide what they are for and what they see.** Intended use: a cleanup step that hides SA internals from the user, e.g. an algorithm logs events every step and the user only wants a binned frequency at the end. Proposal: a finalizer runs only at the end of the whole run, never at the end of a nested plan. Open: what a finalizer of a plan nested in another (repeated) plan means (its result has another shape than the plan's context; putting that into a runtime value is confusing, and it would compute things that may never be used), and what it may read (on `refactor/dsl-locals-rebased` the top-level block keeps its returns after each step so the finalizer can read the last step's returns; that makes the first step change the context's type). Noted 2026-10-12; until decided, finalizers only see what outlives the steps (state, declared locals, inputs).

- [ ] **`FinalizedAlgorithm` (a block with `@finally`) is an `AbstractLoopAlgorithm`, but it can wrap an unresolved plan.** Since `fix/state-scoping`, a plan holds its own states and options and `LoopAlgorithm` only means "resolved", so `FinalizedAlgorithm` is the one wrapper that does not fit that split. Decide what it is (a plan option? a wrapper only after resolve?). Noted 2026-10-08.

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
- [ ] `src/Tools.jl`: `closeprocess(c)` was meant to close the process from inside a step through `_runtime.process`; it never worked (`getglobals` on a process), and steps no longer see the process at all (see `_initial_runtime_context`). Remove it, or give steps a stop request instead.

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

## DSL refactor (proposed 2026-10-06; each item needs the owner's approval first)
Restored 2026-10-09 from `fix/type-stability` (`e1dcbbf`, now tag `archive/type-stability`); the status lines were checked against `main` and the open branches on that date.
- [ ] **Think hard about state in the DSL: who defines it, who owns it, and who may require it.** What a reusable child block promises about its own state, and how `@state` fields relate to `AlgoState` entries (was `ProcessState`), `Init(...)`, `@input` and declared locals.
  - Partly settled on `main` by the `fix/state-scoping` merges (`6dc8fca`..`c6a41e6`): each construction of a block has its own `@state`, nested blocks keep theirs, sharing is written out with `@bind`/`@merge` (`f3414ff`), and one state object can be shared by several blocks (`6108f93`). `@state x` without a default is required at init (`docs/src/internals/dsl_semantics.md`).
  - Still open: the relation to `Init(...)`, `@input` and declared locals. Declared locals are `local x` / `x = 0.0` on `refactor/dsl-locals` (`8d999ff`, not merged; it replaces `Local` from `exp/declared-locals`).
- [ ] Write the DSL design-principles page (three evaluation times, what a bare identifier means, statement table, identity); it replaces the `src/CompositeDSL/Overview.jl` header.
  - The scratchpad draft (`Overview.draft.jl`) is gone. Start from `docs/src/internals/dsl_semantics.md`: `main` has the version from `f3414ff`, `refactor/dsl-locals` a larger one from `dcddb30` (+195/-56 lines against `main`). The two must be reconciled when that branch is rebased.
- [ ] Backend, no behaviour change, one commit per step: (1) a single `_dsl_is_macro(stmt, :name)` helper instead of the hand-written `Symbol("@...")` checks (50 in `src` on `main`); (2) one `RouteInput` struct instead of four NamedTuple `kind`s; (3) one `_dsl_emit_entry` instead of four near-identical emit branches in `_dsl_build_statement`; (4) `@include_if` reuses the block walker.
  - Not started on any branch. `exp/runtime-gen` (not merged) replaces the old lowering (`4764544`: block collector, nested repeat blocks, `Control.jl`, guards), so decide on that branch before doing (3) and (4). Count the passing tests on `main` before starting (854 was the count on 2026-10-06).
- [ ] Frontend, backward-compatible: deprecate `@every` in favour of `@interval`; give `@route`/`@replace` the same option syntax; fix the DSL front-end bugs above.
  - `@every` is not deprecated on any branch. `@replace` is a block option on `main` (`f3414ff`). The question of exposing `Local` as `@local` is answered on `refactor/dsl-locals` by plain Julia `local x` (`8d999ff`, not merged).
- [ ] Docs: restructure `docs/src/user/composite_dsl.md` into tutorial, concepts and reference; shrink the macro docstrings to a pointer plus a syntax summary; expand the README; give `docs/src/index.md` a first-reader path; work through `DOCS_REVIEW_NOTES.md`.
  - Not started. `composite_dsl.md` gained a state section on `main` with the state-scoping work.

## Inspection / ContextAnalyzer
- [ ] `src/ContextAnalyzer/ContextAnalyzer.jl:309`: the analyzer ignores routes and shares, so `inspect` lists routed and defaulted values as unresolved requests.

## Printing, legacy code, exports
- [ ] `src/Printing.jl:51`: `IndentIO` `show`/`print` overloads cause ~400 of the 463 method ambiguities, and `print(iio, "x")` itself throws; `IndentIO` is otherwise unused.
- [ ] `src/Trackers/AlgoBranch.jl:15`: legacy Trackers add global `::Any` fallbacks that hide MethodErrors.
- [ ] `src/Interactive/Interactive.jl:1`: the exported `isinteractive` shadows `Base.isinteractive` in user code.
- [ ] 11 exported names are undefined, and several exported helpers are broken.

## Tests, docs and repo hygiene
- [ ] `ContextExchange` (unused at the moment, see the top of `src/Interactive/ContextExchange.jl`): with `period > 0` it reads the clock on every step (counter-only plan 0.43 -> 11.8 ns per step). Read it less often, with a step budget adapted to how long a step takes. Note that the manual `_step!(la, context)` in `src/LoopAlgorithms/Interface.jl` starts a fresh cursor every call, so children on intervals never get past their first tick; `test/ContextExchangeTest.jl` steps with its own `exchange_stepper` instead.
- [ ] `test/CompositeDSLTest.jl:404`: several DSL testsets only assert that nothing persisted, not the computed values.
- [ ] `test/ProcessManagerTest.jl:286`: threaded paths effectively run serially under the default `Pkg.test`; `ThreadedCompositeAlgorithm` is never executed.
- [ ] `ThreadedCompositeAlgorithm` is an old pattern: decide whether to fix it or remove it. It cannot run as a `Process` at all (`MethodError: no method matching _step!(::BarrieredCompositeAlgorithm…, ::FirstTickCursor…)`: the generated threaded `_step!` in `src/Threaded/Step.jl` only accepts a `CompositeLoopCursor`, the bootstrap step passes a `FirstTickCursor`), and no test runs one. Its direct `step!` path (`_threaded_run_layer`) asserts `::C` on merged contexts, which throws for a traced context on `experimental/context-delta` (a merge grows the trace type); compare `_untraced` types there if it is kept.
- [ ] `test/InlineBenchmarkTest.jl:98`: a wall-clock timing assertion in the unit suite can fail on a busy machine.
- [ ] `docs/src/user/vars.md:27`: `Var(:name)` is still documented, but it can't work in lifetimes because nothing stores globals in a persistent context.
- [ ] `Project.toml`: Documenter is a runtime dependency, there are no `[compat]` bounds, and `[extras]`/`[targets]` are ignored because `test/Project.toml` exists.
- [ ] `test/Manifest.toml` disagrees with the root Manifest (JLD2 0.6.4 vs 0.5.15, Preferences 1.5.2 vs 1.4.3).
- [ ] No CI, so `docs/make.jl` deployment can never run.
- [ ] `LICENSE:8`: the text was corrupted by a global `sub`→`func` rename.
- [ ] About 17.5k lines of snapshots/, diagnostics/ and Profiling/ are tracked, plus `.DS_Store` and `LocalPreferences.toml`, with no `.gitignore`.
- [ ] **Regroup the source folders, after the refactor branches are in main** (DSL, no-first-step, registry; moving files now would conflict with every rebase). `src/ProcessEntities/` holds little more than macro code: `ProcessAlgorithms.jl` (the `@StepAlgorithm`/`@ProcessAlgorithm`/`@init`/`@input` macros, 700-800 lines) is most of it, while the types it is named after (`StepAlgorithm`, `AlgoState`) are in `src/AbstractTypeDefs.jl`, and the other user macros (`@CompositeAlgorithm`, `@Routine`, `@state`) are in `src/CompositeDSL/`. Proposed layout, with `PlanComponents/` as the root for what a plan is built from: the algorithm/state interface (default `init`/`step!`/`cleanup`, `match_by`, `StepResults`) and the states (`GeneralState`, `DynamicStore`, `Destructure`) in one place; all user-facing macros in their own `Macros/` section (`@StepAlgorithm` split into signature parsing, body/`@update` lowering and struct/method generation; `@AlgoState`; the block DSL from `CompositeDSL/`). `AbstractTypeDefs.jl` stays (it loads all abstract types first); internal helper macros in `Functions.jl` stay with the utilities. Do it as a moves-only commit (no code changes) so it is quick to review. Noted 2026-10-16.
- [ ] `src/LoopAlgorithms/Showing.jl:210`: `Base.show(io, ::Type{LA}) where {Plan, LA<:LoopAlgorithm{Plan}}` throws `UndefVarError: Plan` ("not defined in static parameter matching") when printing a `LoopAlgorithm` type whose `Plan` parameter is not bound, e.g. a `UnionAll` inferred type; found when JET printed a report.
- [ ] Packages: replace the random `Unique` ids of the handles inside a `Package` by plain sequential ids when the package is built (no reconstruction), so package types are the same on every re-run. Nothing looks up a handle inside a package by its original handle today (`test/PackageTest.jl` uses the package handle itself); check that before changing it.
- [ ] `resolve` decides at run time whether a plan has `Unique` handles by walking its children, states and options (0.42 µs measured on a 6-child plan without `Unique`, below 0.05 µs when a `Unique` comes first). A `Bool` field set once in `_build_plan` (true when any child, state or option is a `Unique` handle or a plan with the flag set) would make that a field read. Every plan struct (`CompositeAlgorithm`, `Routine`, `ThreadedCompositeAlgorithm`, the `LoopAlgorithm` wrapper) and every place that builds or edits a plan would have to keep it right; a stale flag only costs speed (missed `true`: recompiling per re-run; missed `false`: normalizing for nothing).
- [ ] Hot loop, memory traffic per step: the loop reads and writes `Process.loopidx` and `Process.tickidx` on every step (`inc!`/`tick!` in `src/Loops.jl`) and reads `shouldrun` atomically (`src/Process.jl`). Keep both counters in local variables during the loop and write them to the `Process` every N steps (the interface reads `tickidx` about 30 times a second), and check `shouldrun` every N steps too; flush the counters when the loop exits. The atomic `shouldrun` read is suspected to cost a few percent on the InteractiveIsing 3D graph example; measure it with the endless `createProcess` test (5 alternating rounds) once main is back to the speed of the June version.
- [ ] Hot loop, context copy: each step copies the whole context (624 bytes for the InteractiveIsing 3D graph example; `llvm.memcpy`/`llvm.lifetime.start` of the context in the compiled `loop`). Cause: when a step leaves the context unchanged, `context` is a loop variable whose new value is itself; Julia keeps such a struct of pointers and plain values in a stack slot and copies it every step. Experiments: `experimental/context-delta` (the loop carries only the fields its steps write, found by inference; 3D graph 206 -> 512 updates/s/spin), `experimental/trivial-phi-loop` (removes the trivial φs from the IR, compiler internals; 514), `exp/phi_native_fix` (rebuild the context from its fields every step, old loop pattern; 340).
- [ ] Composite step counter: `inc!(cursor::CompositeLoopCursor, ca)` (`src/LoopAlgorithms/CompositeAlgorithms.jl`) keeps the counter in a `Ref` on the heap. Since commit 9a5bc83 it skips the update when the cycle length (lcm of the intervals) is 1; that made the InteractiveIsing 3D graph example about 2.5% slower (endless test, 5 of 5 rounds), although it removes a store, because the loop's code is laid out differently once nothing uses the cursor. Keep the counter in a local variable the loop carries from step to step instead of a `Ref`, so the loop no longer depends on whether that write happens.

## Later: step returns and declared locals (from the locals design, 2026-10-02)
- [ ] Rule to document and check (at resolve / `inspect` / debug mode, not per step): a step's returned fields and their types depend only on the types it gets, never on values (no `cond ? (; a, b) : (; a)`). "Sometimes" belongs in the schedule.
- [ ] Maybe allow a field that is `nothing` for now, if the step returns that field from the start (a guard value, or an explicit `Union{Nothing,T}` in the return). Must not box the context, and the context after the step must stay type-compatible with the initial one. Unsure it fits the pattern.
- [ ] DSL: printed plans show a call's wired arguments by context key (`plus_capture.captured`, `_state.b`), not by the DSL alias the author wrote (`c1.plus_capture.captured`, `b`); the alias only exists in the DSL.
- [ ] Plan edits (rename/insert) re-attach child-local wiring by matching the child object; two equal children (same unkeyed algorithm type, or identical `Callable`s) with different wires would both get both. Re-attach by position (re-wrap in `WithWiring`) instead.
- [ ] Remove `LocalPlanOption` once the DSL no longer uses it for algorithm statements.

## Later: algorithms written by signature (from the step!-call experiment, 2026-10-02)
- [ ] Multi-method algorithms in the signature form: one algorithm type with several `step!` methods taking different arguments (different names, or the same names with different types). The plan unpacks values before the user's code, so it has to choose which method's names to read, at compile time. Needs a rule, e.g. Julia's own dispatch on the types of the values the view can see, or the most specific method whose names are all visible, plus a clear error when none or several match.
- [ ] Make the signature form (`@StepAlgorithm` / a declared signature) the documented way to write algorithms; keep `step!(a, c)` with the whole-context view as an escape hatch (it stays force-inlined). Measure the compile-time gain on a real plan (`Demos/gray_scott`) first.

## Later: named plans as context slices (2026-10-03)
- [ ] Let a nested plan have a name for user convenience: `context[:name]` gives the slice of the context made of the plan's children (their SCKeys, including those of plans nested inside it). The plan still gets no namespace of its own; the name only stands for its children's. Read-only: a plan name is not a valid SCRef for routes/shares (it doesn't say which child). Today `:name => plan` is rejected at construction (`LoopAlgorithms/Setup.jl`, "cannot currently be passed as pairs"), but `IdentifiableAlgo(plan, :name)` and `insert(la, i, :name => plan)` get past that check, and the name is then silently dropped during registration (`Preparation/Constructor.jl`, `add_algo_to_registry` for a named plan; `PlanOptions.jl`, `_child_wiring_for_child` for a named plan). Those two methods are where the name would be recorded (`:name => (child SCKeys...)`) instead of dropped. Until then, either reject the name on those two routes as well or leave them.

## Optional: naming cleanup
- [ ] (optional) Rename `from_match_by` / `to_match_by` (routes and `Replace`) to `source_matcher` / `target_matcher`: they read the stored identity of a route's endpoints from its type, and "match by" only reads well if you know `match_by`. Pure rename across the routing code; best done in a general cleanup pass, together with removing any one-use forwarding functions (`foo(x) = _foo(x)`).

## Cleanup: `src/AbstractTypeDefs.jl`
- [ ] The file is meant for abstract types only, but holds 19 concrete structs and ~13 functions/consts next to 16 abstract types: plan and loop runtime (`LoopAlgorithm`, the loop cursors `NoLoopCursor`/`CompositeLoopCursor`/`FirstTickCursor`/`DirectRoutineCursor`/`PausableRoutineCursor`, `Namespace`, `Resuming`, `Generated`/`NonGenerated`), wiring (`Wiring`, `PlanWiring`, `PlanWiringView`, `LocalPlanOption`, `ReturnDemand`), and constructor parsing (`Static`/`Dynamic`/`Greedy`, `IfWrapped`). Move each next to the code that uses it (loop cursors to `LoopAlgorithms/LoopCursor.jl`, wiring to `RoutingInterface/`, ...) and keep only the abstract types here. Check include order: some files rely on these being defined early.
