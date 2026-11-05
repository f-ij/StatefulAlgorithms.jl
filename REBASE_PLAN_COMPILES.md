# Rebasing `refactor/plan-compiles`: what to port

`refactor/plan-compiles` branched from `main` at `4f35d638` (2026-10-26). Since then `main` got
`refactor/contexts-processes-pausing` (fast-forwarded 2026-11-04, tip `35a00a31`) and `ce84c26d` (redirect cycles at
resolve). `refactor/plan-holds-no-data` sits on `35a00a31`. When plan-compiles is rebased onto these (and onto
`refactor/partitions`, BRANCHES.md), every rename, removal, move and design rule below has to reach its code, or its
code has to be rewritten into the new place. This file collects them in one place. Before, they were spread over
commit messages and TODO.md items.

Read with it: TODO.md items "Construction pipeline" (decisions 1–9), "A plan holds no data", "Where the lifetime
lives", "Names of the `Process` run path", "Finalizers", "When `refactor/partitions` and this branch are combined".

Keep this file up to date: a commit on `refactor/plan-holds-no-data` (or on `main` before the rebase) that renames,
removes or moves something plan-compiles uses adds a row here.

## 1. What plan-compiles has that collides

plan-compiles built its own process/session design first. `refactor/contexts-processes-pausing` rebuilt it on `main`
without the `UniqueKeyMap` parts, and later commits changed it again. On the rebase, keep the main/this-branch version
and put plan-compiles' map work into it:

1. **Where the map is dropped.** plan-compiles drops the `UniqueKeyMap` with `strip_keymap` at its `makeloop!` /
   `prepare_loop` call sites and in `_prepare_process`. Here the one hand-off of every run is
   `prepare_for_loop(owner, context, inputs, resume) -> (session, plan, loop_context)`
   (`src/Processes/Hooks.jl`, methods per process type and for `run(plan, context)` in `src/LoopAlgorithms/DirectRuns.jl`).
   That is where the map, later maybe the whole registry, is dropped. Nowhere earlier: the user's context keeps the
   map in its registry (TODO.md, UniquePlanId items; `exp/ukm-in-registry`).
2. **No `makeloop!`.** Removed (`1ab7a5ee`): `run(p)` calls `_start_run!(p, inputs; resume)`, which prepares the run
   and starts its task. The typed/dynamic split and the lifetime variants are gone, and so is `ProcessTaskBody`
   (a closure now).
3. **No `create_session` and no session copy.** `prepare_for_loop` uses the process's own session (`getsession(p)`).
   The run's lifetime lives in the session (`cef76251`): `InteractiveSession{C}` with `lifetime::Lifetime`, no `LT`
   parameter, so a lifetime of another type never needs a new session. Read and set it through the session's own
   `getlifetime(session)` / `setlifetime!(session, lt)` (pure store), never the field. `run(p/tp; repeats/lifetime)` sets
   it, falling back to the process's `default_lifetime` (the field was `lifetime`); a resume keeps it
   (`repeats`/`lifetime` on a resume are an error); `reset!` restores the default; `setlifetime!(p, lt)` only sets
   `default_lifetime` and warns on a running or paused process. `prepare_for_loop(owner, context, inputs, resume)`
   lost its lifetime argument; the loop still gets `getlifetime(session)` as an argument. The manager passes a job's
   lifetime as the run's, not through `setlifetime!`. This replaced the session swap of `07d5afc4`
   (`set_session_lifetime!`, before it `adapt_session`/`create_session`). perf's `NoStopRepeat` runner is removed
   until an uninterruptible-run API exists (TODO.md, "An uninterruptible run").
4. **The plan holds no context.** plan-compiles' `Process{F,C}` holds the plan with the map-carrying registry and
   reads the context through it (`getpersistentcontext`, `context(p)`). Here the process holds the context itself
   (`state_context`, read with `getcontext(p)`), and the plan (`LoopAlgorithm{Plan, O, R, id}`) holds only plan,
   options and registry. The map goes into the registry of the context the process holds.
5. **`InlineProcess` type parameters.** plan-compiles: `InlineProcess{TD, ContextType, Lt, A}`. Here:
   `InlineProcess{TD, ContextType, Lt, S<:Tuple}`, where `S` is the type of its fixed, typed specs (`8794bba2`). There is no mode
   parameter and no threaded or async path. A plan-compiles parameter for the map would be added next to these.
6. **Lifetime `Var`s resolved before the loop** (`resolve_vars`, plan-compiles `fb15e0a`, `99a34d8`) were not ported.
   They need plan-compiles' `Var` redesign and come with its rebase, inside `prepare_for_loop`.
7. **Precompile calls.** plan-compiles calls `precompile_interface` with loop precompiles. Here there is one hook,
   `precompile_interface(x)` (`src/PrecompileInterface.jl`, same shape), which compiles nothing by default. The Process and
   InlineProcess constructors call it. The loop precompile stubs were removed (`00de6df4`). Port plan-compiles'
   precompile methods onto `_run_loop_and_store!` (the task body, `@noinline`).
8. **Redirect cycle check.** `main` (`ce84c26d`) checks cycles at resolve: `check_redirect_cycles(registry, options)`
   at the end of `_resolve_keyed_plan` and `_resolve_plan_typed`. This branch still checks at every init from the
   context's markers (`check_redirect_cycles(context)` in `apply_redirect_specs`). The rebase onto `main` takes main's
   version. Owner wants it typed (TODO.md, "Redirect cycle check typed").
9. **Registry lookup without try/catch** (`589fbfd7`). `get(reg, obj, default)` (`src/Registry/Registries.jl`) finds
   the entry of `obj`'s type (`find_typeidx`, `default` when there is none), then `findfirst_match` (by matcher or by
   the runtime table, depending on `isstaticallyfindable`), `default` when nothing matches. plan-compiles' changes to
   registry lookups go onto this version. Owner's rule: resolving a reference is one lookup in the registry, no
   try/catch, no intermediaries (TODO.md, `aa7a7cc7`).
10. **`ProcessContext(plan)` warns on an unresolved plan** (`507531f1`): resolve first. A plan-compiles caller that builds
    a context from an unresolved plan starts warning; it should resolve, or call `ProcessContext(registry)`.

## 2. Renames

| Old (as on plan-compiles) | New | Where now | Commit |
|---|---|---|---|
| `process_breakcondition` | `session_breakcondition` | `src/Sessions/Hooks.jl`, methods in each `Processes/<type>/Session.jl` | `ae5de93c` |
| `_prepare_for_loop` / `prepare_loop` | `prepare_for_loop` (a hook, no `_`) | `src/Processes/Hooks.jl` | `4e8a2653` |
| `_finish_run!` | `_store_run_contexts!` | `src/Processes/Process/Loop.jl` | `88eaefce` |
| `_run_process_task` | `_run_loop_and_store!` | `src/Processes/Process/Loop.jl` | `88eaefce` |
| `_start_new_run!`, `_resume_paused_loop!`, old `_start_run!`, `_launch_run!` | `_start_run!(p, inputs; resume)` | `src/Processes/Process/Loop.jl` | `88eaefce`, `35a00a31` |
| `_loop_ispaused`, `_keep_loop_cursor!`, `_clear_pause!` | `loop_ispaused`, `keep_loop_cursor!`, `clear_pause!` (session hooks, no `_`; also `starting_cursor`) | defaults in `src/Sessions/Hooks.jl`, `InteractiveSession` methods in `src/Processes/Process/Session.jl` | `1992e4cf` |
| `session.lifetime` (field read/write) | `getlifetime(session)`, `setlifetime!(session, lt)` (methods of the process accessors for `InteractiveSession`; pure store) | `src/Processes/Process/Session.jl` | `1ba36c92` |
| `commit_context!` | `_sync_state_context!` | `src/Processes/Process/Accessors.jl` | `e7cc9fea` |
| `context(p)`, `context(ip)`, `context(la)`, worker/slot `context` | `getcontext` (exported) | per type's `Accessors.jl` | `f9886eb6` |
| InlineProcess context setter | `setcontext!` (exported, pure setter) | `src/Processes/InlineProcess/Accessors.jl` | `f9886eb6` |
| `makecontext!(::Process)` | `setcontext!(p, c)` (pure: only stores) | `src/Processes/Process/Accessors.jl` | `ade5fc10`, `82e28e6b` |
| `loopint(p)` | `getlidx(p)` (exported) | | `f9886eb6` |
| `lifetime(p)` (from `@setterGetter Process`) | `getlifetime(p)` (exported) | per type's `Accessors.jl` | `d07290de`, `07d5afc4` |
| `normalize_process_algo` | `parse_plan` (`normalize_process_algo` kept as a deprecated alias for InteractiveIsing) | `src/Processes/Construction.jl` | `277e834f`, `33d6097e` |
| `normalize_lifetime_arguments`, `normalize_process_lifetime`, `_is_routine_plan` | `parse_lifetime(lifetime, repeats)` + `default_lifetime(plan)` | `src/Processes/Construction.jl` | `277e834f`, `07d5afc4` |
| `stored_value_at` | `getproperty_raw` | `src/Context/Vars.jl` | `40d08c55` |
| `_runtime_values` | `runtime_values` (hook) | `src/Context/Bundles/Hooks.jl` | `075902d4` |
| `_rebundle` | `rebundle` | `src/Context/Bundles/` | `b4667775` |
| `_build_process_context` | `ProcessContext(registry)` (empty context from the registry, no init) | `src/Context/` | `ce7953b9` |
| `HeadlessRuns.jl` | `DirectRuns.jl` | `src/LoopAlgorithms/DirectRuns.jl` | `d396a081` |
| `Init(...)` (and the `Input` alias) | `InitArgs(...)`; `Input` removed | `src/InputInterface/StructDefs.jl` | `a0291e0a` |
| `AllInitTargets`, `isalltargets` | `ToAll()`, `_is_to_all_ns` | `src/InputInterface/` | `4050fcca` |
| `reinitworker!` | `initworker!` (= `init!` on the worker) | `src/Manager/ProcessManager.jl` | `a0291e0a` |
| `initcontext(context, identified_algo; inputs, overrides)` | `init_namespace` (internal) | `src/Context/Init.jl` | `07d5afc4` |
| `VarLocation{Type, ...}` (first type parameter) | `VarLocation{Kind, ...}` | `src/Context/View/VarLocation/StructDef.jl` | `6727b4dc` |
| `Process{F, LT, C}` | `Process{F, C}` (run fields on the session) | | `8dd09746` |

## 3. Removed

| Removed | Use instead | Commit |
|---|---|---|
| `makeloop!` (typed/dynamic split, lifetime variants), `ProcessTaskBody` | `_start_run!` | `1ab7a5ee` |
| `create_session`, `adapt_session`, the session copy, `set_session_lifetime!` | the process's session, which holds the run's lifetime (`getlifetime(session)`) | `4df2c7ab`, `2c271525`, `07d5afc4`, `cef76251` |
| `LoopRunProcess` | an `InlineSession` per direct run | `8dd09746` |
| `_loop_persistent_context`, `_loop_runtime_context` | `loop`/`run_session_loop` take `(session, plan, loop_context, lifetime, resume)` | `2aba4abe` |
| `_paused_visible_context`, `_paused_state_context`, `_clear_paused_subcontext`, `_store_runtime_context!`, `context(p::Process, c)` | the pause split: state context + `p.runtime_context` | `e7cc9fea` |
| `InlineProcess` mode parameter, `threaded` keyword, `isthreaded`/`isasync` for it | `InlineProcess` runs in the caller's task only | `b0f1f214` |
| `repeat` keyword (constructors, manager launches) | `repeats` | `670761c6`, `07d5afc4` |
| `run(p; repeats/lifetime)`, `run(tp; ...)`, positional `run(p, lt)` | `run(p/tp/ip; repeats/lifetime)` is a per-run lifetime (stored in the session, `setlifetime!(session, lt)`, for `Process`/`TimedProcess`, never in the process); no positional lifetime; `setlifetime!(p, lt)` changes the default | `07d5afc4`, `ceda37a8`, `cef76251` |
| `getpersistentcontext`, `getstoredinits`, `getstoredoverrides`, `getcontext(la)`, `_with_lifecycle`, `_without_lifecycle`, `FinalizedAlgorithm` forwards, `src/Copy.jl` | the user or the process holds context and specs | `11e859a7` |
| plan-level `init(la, specs...)`, `partialinit`, `run(la; ...)` | `setup(plan_spec, specs...) -> (context, plan)`, `run(plan, context) -> (context, result)`, `init(plan, context, [Only(...)], specs...)` | `23f5c6b7`, `11e859a7`, `a0291e0a` |
| `reinit(plan, context, ...)`, `reinit(p)`, `reinit(p, target; ...)`, backend `init(plan, ::AbstractContext)` | `init(plan, context, ...)`, `init!(p, ...)` | `a0291e0a` |
| `partialinitworker!` | `initworker!(slot, Only(...), ...)` | `a0291e0a` |
| `initcontext(algo, [c], specs...)` (`src/Init.jl`), `initcontext(context, ::Symbol / algo)` | `setup`; `init(plan, context, Only(...), ...)` | `07d5afc4` |
| `makecontext`, `makecontext!` | `init!(p, ...)` | `07d5afc4` |
| `init!(ip::InlineProcess, ...)` | `init(ip, ...) -> InlineProcess` (new process with the merged specs); `init_and_run(ip, ...)` = `run(init(ip, ...))` | `d3423980` |
| `reset!(ip::InlineProcess, ...)` | `Base.reset(ip, specs...) -> InlineProcess` (fresh context from the merged specs, which it keeps; no `Only`); `reset!` stays for `Process` (export moved to `Process/Lifecycle.jl`) | this commit |
| `_initial_runtime_context` (plan-compiles calls it in `Context/ContextBundles.jl`, `Loops.jl`, `ProcessInteraction.jl`) | `LoopContext(plan, context)` (declared locals start there) + `with_inputs(lc, plan, inputs)` for a new run; a pause's runtime context is kept whole (`p.runtime_context`) | `2aba4abe`, `3b0c4969`, `e7cc9fea` |
| `_resolve_input_target_key` (`src/InputInterface/Resolving.jl`) | `resolve(reg, ::InputInterface)` calls `static_findkey` / `getkey(get_by_matcher(...))` directly | `a489de1f` |
| `_has_typed_state_context`, `_typed_state_context` | manager launches from `getcontext(worker)` | `11e859a7` |
| `@DebugMode`, `@GenDebugMode`, `DEBUG_MODE`, `debug_mode()`, `Debugging.jl`, the Preferences dependency, `LocalPreferences.toml` | nothing | `1fc7b986` |
| `shown_value` hook, `_shown_values` | nothing (it returned its argument everywhere) | `763e1a37` |
| `@setterGetter Process`, `run!(::Process)`, `start_finished` | accessors | `d07290de` |
| positional `VarLocation(type, ...)` constructor | `VarLocation(...)` with typed arguments | `943dd99c`, `18ac9042` |
| Process precompile stubs (`schedule_loop_precompile!`, `wait_loop_precompile!`, `precompile_loop!`, `_callable_instance`) | `precompile_interface` | `00de6df4` |
| exports of undefined names: `preparedata!`, `getallocator`, `getnewallocator`, `InlineProcessAlgorithm` | | `23f5c6b7`, `742fe57b`, `82e28e6b` |

## 4. Moved files

plan-compiles still has the old layout. Its changes to these files go into the new places:

| On plan-compiles | Now |
|---|---|
| `src/Process.jl`, `ProcessInteraction.jl`, `ProcessStatus.jl`, `ProcessList.jl`, `Listeners.jl` | `src/Processes/Process/` (`StructDef.jl`, `Constructors.jl`, `Session.jl`, `Accessors.jl`, `Loop.jl`, `Lifecycle.jl`, `Status.jl`, `ProcessList.jl`, `Listeners.jl`, `Copy.jl`, `Tools.jl`, `Showing.jl`); `Process.jl` only includes the folder |
| `src/InlineProcess.jl`, `InlineProcessShowing.jl` | `src/Processes/InlineProcess/` (same split) |
| `src/TimedProcess.jl` (not included there) | `src/Processes/TimedProcess/`, rewritten on the Process design (`62ac0c98`) |
| `src/AbstractProcesses/` | `src/Processes/` (`AbstractProcesses.jl`, `Interface.jl`, `Hooks.jl`, `Accessors.jl`, `Construction.jl`, `Context.jl`) |
| `src/Sessions/InlineSession.jl`, `InteractiveSession.jl` | `src/Processes/<type>/Session.jl` (each with its session-hook methods); `src/Sessions/` keeps the abstract type, interface and hook defaults |
| `src/Copy.jl` | removed (plan copy); process copy in `src/Processes/Process/Copy.jl` |
| plan-level `init`, `partialinit`, `run(la)`, `_init_context_for`, `_split_init_override` in `src/LoopAlgorithms/RuntimeInputs.jl` | `src/LoopAlgorithms/DirectRuns.jl` (`08f54c3f` moved them to HeadlessRuns.jl, `d396a081` renamed it); plan-level `init`/`partialinit`/`run(la)` since replaced by `setup`/`run(plan, context)`/`init(plan, context, ...)` (§3). `RuntimeInputs.jl` keeps the runtime-input checks (`_validate_runtime_inputs`, `with_inputs`); its stored-context getters (`getstoredinits`, ...) went to `LoopAlgorithms/Accessors.jl`, then were removed (`11e859a7`) |
| `src/Debugging.jl` | removed |
| Context bundles (`LoopContext`, `InitContext`) | `src/Context/Bundles/` (`075902d4`) |
| Storage wrappers, read/write/show hooks (`Context/View/...`) | `src/Context/StoredValues/` (`StorageWrappers/`, `Hooks.jl`, `ReadingWriting.jl`) (`14078d59`, `24eff79a`) |
| `VarLocation` in `src/Context/View/StructDef.jl` | `src/Context/View/VarLocation/` (`StructDef.jl`, `Accessors.jl`); `View/StructDef.jl` holds only `SubContextView` (`943dd99c`) |
| `src/Context/View/Old/ProcessContextView.jl` | `src/Threaded/OldProcessContextView.jl` (`75ad9ec8`) |
| Write-set rules (`ProcessAlgorithmStep.jl`, `Callable/Step.jl`, `Step.jl`, `Threaded/Step.jl`) | `src/Context/Carried/` (`f1b86cb7`) |
| Lifetimes | one file per type in `src/Lifetimes/`, each with its `lifetime_breakcondition` method |

## 5. Design rules plan-compiles has to follow after the rebase

1. **Sessions.** The loop, the steps and the lifetimes take a `ProcessSession`. `InlineSession` holds only the loop counter.
   `InteractiveSession{C}` adds ticks, times, the `shouldrun`/`paused` flags, the paused cursor, the thread and the run's lifetime. The
   session belongs to the process, and the loop reaches it through `run_session_loop`.
2. **Every run starts at `prepare_for_loop`**, which hands the loop a `LoopContext`. For a new run the inputs are checked and
   added by `with_inputs` on top of `LoopContext(plan, context)`.
3. **Pause split.** A pause takes the `LoopContext` apart. The persistent values go into the process's
   `state_context` (`_sync_state_context!`, which keeps the user handle's registry), and the runtime context (inputs,
   declared locals) goes into `p.runtime_context`. Resume and close put the two together again and clear the slot.
   `getcontext(p)` is always the state context.
4. **A plan holds no data.** The context and the specs belong to the user (`setup`) or to the process
   (`state_context`, `specs`, `getspecs(p)`). Stored specs are resolved once and merged per target. Resolving an
   already resolved spec (a `Symbol` target) does no lookup by name, it only drops the ref (`8cd5015f`), so stored
   specs go through `resolve` like any others: `reset!(ip)` and `close`'s error path call
   `setup(getalgo(p), getspecs(p)..., specs...)`, `init!`/`copyprocess` pass the stored specs in front of the new ones
   (`_merged_lifecycle_specs`, no `base` argument). Never add a lookup by name on these paths: one in the precompile
   workload makes the package image fail to load on Julia 1.13.1.
5. **Init interface.** `InitArgs` (values) and `Only(...)` (which `init` runs) are separate. `init!(p, ...)` for
   `Process` and `TimedProcess`; `init(ip, ...)` for `InlineProcess` returns a new process (`const specs::S`, typed
   context), as does `reset(ip, ...)`. Every process keeps the merged specs. Rule: a function that changes typed data
   has no `!` and returns a new process; every `InlineProcess` call that changes it returns a new one.
6. **Lifetime.** The process holds a default (`default_lifetime`, `getlifetime`); `run` never changes it. A run's own
   lifetime (`repeats`/`lifetime` on `run`, else the default) is in the session and survives a pause. `setlifetime!`
   (Process, TimedProcess; warns during a run) and `setlifetime` (new process; the only one for `InlineProcess`).
7. **Pure accessors.** `setcontext!` and `_sync_state_context!` only store; callers pause first (memory and TODO.md,
   "Later: a sync mode").
8. **Interval semantics** (`0c05ec68`, `e8049a17`, `7a60a823`). A number given as `first` runs on that tick. `child * parent` is
   the child's schedule after flattening. Offsets skip ticks once (the composite counter cycles up to
   max offset + lcm). The schedule-field work (`intervals::Intervals`, `repeats::Repeats`, `compute_multiplier`,
   `multipliers(plan)`) was already on `main` at plan-compiles' base.
9. **Hooks** have no `_` prefix and live in the folder's `Hooks.jl`. A type's hook methods go in a delimited section
   at the end of the file that defines the type.

## 6. Agreed, not implemented yet (the rebase must not contradict these)

1. Finalizer rules (TODO.md, "Finalizers", 2026-11-04): the composer owns the finalizer; on by default with a
   `finalize = false` opt-out; `c = run(...)` when there is none, `c, r = run(...)` when it runs; it runs at every run end
   before cleanup.
2. `Only` changes again with `refactor/partitions` (TODO.md construction pipeline item 9).
3. `refactor/partitions` rewrites the `VarLocation` part of the old `View/StructDef.jl`, and its changes go into
   `Context/View/VarLocation/` (TODO.md item). partitions still uses the old name `stored_value_at`.
4. Redirect cycle check: typed, from the `Redirect` types (TODO.md).
5. Where the manager's per-job lifetime goes (TODO.md, "Per-job lifetimes in the manager").
6. Runtime context as its own type, `ProcessContext` → `StateContext` (TODO.md, "Modes of operation").
7. A spec with a `Symbol` target is no longer checked against the registry in `resolve` (was `@assert haskey(reg,
   target)`), and neither are stored specs when `copyprocess` builds a process from another plan. Check the targets
   once at construction (`setup`, process construction, `_stored_specs`), without a lookup by name in the precompile
   workload (TODO.md, construction pipeline item 10, for `refactor/partitions`).
