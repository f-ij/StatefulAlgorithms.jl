# TODO: parked non-core issues

Parked on 2026-09-25 while work focuses on core stability and speed. These issues are all outside
the core (entities/identity, registry/routing/context, loop algorithms, loop kernel, Process/InlineProcess).
Each was reproduced in the September 2026 code review unless marked *(unverified)*.

## Process bookkeeping (touches the `Process` constructor)
- [ ] `src/ProcessList.jl:6`: the global `processlist` Dict is mutated without a lock, so concurrent `Process` construction (e.g. OnDemandWorkers under threaded execution) corrupts it.
- [ ] `src/ProcessList.jl:6`: bookkeeping never works: wrong key, `quit` and the finalizer never remove entries, `quitall` throws, and the Dict grows without bound.

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
- [ ] `src/Saving.jl:12`: `savecontext` always throws, there's no load counterpart, and JLD2 is only used here (inline TODO).
- [ ] `src/Tools.jl:176`: `progress()` reports 0.0 once a completed process is closed *(unverified)*.

## Packaging and threaded composites
- [ ] `src/Packaging/StructDef.jl:19`: `Package` keeps a mutable schedule counter in the algorithm value, shared by every process using it.
- [ ] `src/Packaging/Step.jl:4`: children's same-named variables silently collapse into one package namespace.
- [ ] `src/Threaded/Step.jl:101`: `ThreadedCompositeAlgorithm` runs sequentially; the threaded path is unreachable from `run`/`Process` and broken.

## DSL front-end
- [ ] `src/CompositeDSL/Statements.jl:545`: `Algo()`-form ProcessState entries are registered as stepped children.
- [ ] `src/CompositeDSL/Statements.jl:480`: aliased ProcessState entries lose their alias key, so `alias.field` routes point at a missing key.
- [ ] `src/CompositeDSL/Statements.jl:391`: `@input` inside `@include_if` is ignored, but its name stays routable.
- [ ] `src/CompositeDSL/References.jl:11`: `@context` with a builder call is broken.
- [ ] `src/CompositeDSL/Invocations.jl:252`: captured non-isbits keyword values in function-call entries fail at construction.
- [ ] `src/CompositeDSL/Macros.jl:93`: unresolved route sources are silently dropped (typos, same-named globals, skipped `@include_if` producers).
- [ ] `src/CompositeDSL/StateAndRoutes.jl:173`: hygiene problem: escaped expressions contain `StatefulAlgorithms.`-qualified names, so they fail if the caller hasn't bound that module name.
- [ ] `src/CompositeDSL/Macros.jl:53`: the DSL re-implements the constructor parser, and the copy has drifted (no `RunIf`).

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
