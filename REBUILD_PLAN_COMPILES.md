# Rebuilding `refactor/plan-compiles` on `main`: handoff

`refactor/plan-compiles` is rebuilt from scratch on top of `main`, one old commit at a time. The old branch is kept as
`refactor/plan-compiles-old` (folder `StatefulAlgorithms.jl-plan-compiles-old`, tip `6830c9d1`, base `4f35d638`,
2026-10-26). The new `refactor/plan-compiles` (this folder, `StatefulAlgorithms.jl-plan-compiles`) started at `main`
`036b61ed` on 2026-11-05. Decided by the owner on 2026-11-05: a literal `git rebase` does not work, because `main`
split and moved most of the files the old branch changed (`Process.jl` alone became 12 files). So every old commit
is ported by hand: make the same kind of change on `main`'s code, in `main`'s files.

`origin/refactor/plan-compiles` on the remote still points to the old tip. Do not push the new branch over it
without asking the owner.

## 1. Read first

1. `REBASE_PLAN_COMPILES.md`: every rename, removal, file move and design rule on `main` since `4f35d638` that the
   old code has to follow. §4 maps old files to new ones, §2/§3 list renames and removals, §5 the design rules,
   §6 what is agreed but not built yet (do not contradict it). An agent wrote it, so check it against the code where
   it matters. If the doc and the code disagree, ask the owner.
2. TODO.md items named in that doc's header ("Construction pipeline", "A plan holds no data", "Where the lifetime
   lives", "Names of the `Process` run path", "Finalizers", "When `refactor/partitions` and this branch are
   combined"), plus the UniquePlanId items.
3. `BRANCHES.md`: the refactor stack. `refactor/monolithic-resolve`, `exp/replace-ids-cache` and `exp/resolve-cache`
   still sit on the old branch. They get rebuilt after this one, not now.

## 2. Per commit

For every row of the table in §5, in order:

1. Read the old commit: `git -C ../StatefulAlgorithms.jl-plan-compiles-old show <hash>`, plus its message (the
   messages say why).
2. Find where each changed piece of code lives on `main` (§4 of `REBASE_PLAN_COMPILES.md`; `grep` for the function
   names; check §2 for renames).
3. Decide if the commit is **straightforward** (point 4) or needs the **owner** (point 5).
4. Straightforward: apply it directly. Run the tests (§4), commit, set the row to `done` with the new hash.
   Straightforward means that the same change can be made on `main`'s code with no design choice left:
   1. the code only moved to another file or folder, or was renamed (§2), and the old change applies to it as it is;
   2. docs, comments or TODO lines that still fit `main` (put TODO text in `main`'s TODO.md at the item it belongs
      to; drop lines that `main` already settled, and say so in the commit message);
   3. code that `main` left alone.
5. Ask the owner, **one commit at a time**, before changing anything, when:
   1. the code the commit changes was rewritten on `main`, not just moved (processes, sessions, `makeloop!`,
      `create_session`, precompile, loop hand-off, plan-level `init`/`run`; `REBASE_PLAN_COMPILES.md` §1 and §3);
   2. the commit clashes with a rule in `REBASE_PLAN_COMPILES.md` §5/§6 or a TODO.md decision;
   3. there are two reasonable ways to port it, or it would mean dropping part of the commit;
   4. a later old commit reverts or replaces this one (§3, point 3), and skipping or squashing would make sense;
   5. tests fail and the fix is not obvious.
   Show the owner: the old commit (hash, message, what it changes), where that code lives on `main` now, what
   differs, and your proposal. Then wait. Record the owner's answer in the row's notes.
6. Rows marked `skip` or `squashed into #n` count as done. Write why in the notes.

## 3. Known points to raise early

1. **Twins on `refactor/partitions`.** Rows marked "twin on `refactor/partitions`" (#83, #84, #100, #103, #106)
   exist there in a reworked form too. `refactor/partitions` is not in `main` (26 commits ahead, under review). Ask
   at the first one whether to port them here or leave them until partitions is in `main`. Later commits build on
   them (the `Var`/`VarLocation` and nsref/partref work), so the answer decides the order of the end of the table.
2. **`HookExtensions.jl` files.** The old branch adds `Context/View/HookExtensions.jl`,
   `Identifiable/UniquePlanId/HookExtensions.jl` and `Sessions/HookExtensions.jl`. `main`'s rule (TODO.md, the
   hook-extensions item; `REBASE_PLAN_COMPILES.md` §5.9): a type's hook methods go in a delimited section at the end
   of the file that defines the type; a separate `HookExtensions.jl` only for a type that has its own folder of
   several files. So `UniquePlanId/` keeps its file; the others go to the files of their types.
3. **Old commits undone later on the old branch.** Port the pair together or skip both? Ask:
   1. #15 `620e8ad7` user-context cache, reverted by #16 `20e1cf78`;
   2. #74 `bd39c32b` IndentIO commented out, brought back by #89 `d34c7d34`;
   3. #69 `02a3bdda` and #80 `4ace8b5b`/#88 `ea206e5d`: a cache added, then "No caches" (no global caches outside
      `exp/*` branches);
   4. #94 `6eb222d0` generated `LoopContext`, plain again in #95 `83f47323`;
   5. #29 `fb15e0a9` inlined loop, a call again in #30 `99a34d80`;
   6. the precompile chain #31–#38 (`d8afa544` … `431672ec`): `main` has its own `precompile_interface`
      (`REBASE_PLAN_COMPILES.md` §1.7);
   7. the process/session chain (#24 `4d040669`, #25, #27, #28, #39, #85, #86, #92–#96, #99): `main` built its own
      session design (`REBASE_PLAN_COMPILES.md` §1). Port only what `main` lacks (the `UniqueKeyMap` parts), into
      `main`'s design.
4. Commits that only touch docs/TODO about the old process layout (#58, #61, #63–#65 "Process files TODO") are
   probably settled by `main`'s `src/Processes/` layout. Check each against TODO.md and skip what is settled.

## 4. Working rules

1. Work and commit only on `refactor/plan-compiles` in this folder. Check the branch and `git status` right before
   each commit; stage files by name.
2. One new commit per old commit (or per owner-approved group). Message: the old subject, adapted to what the new
   commit does, then a line `Ported from refactor/plan-compiles-old <hash>.` Note what was dropped or changed and
   why. No `Co-Authored-By` trailer.
3. Tests run sequentially: `SA_TEST_SERIAL=1 julia --project -e 'using Pkg; Pkg.test()'` (the parallel runner
   hangs). One file: `JULIA_LOAD_PATH="$PWD/test:$PWD:@stdlib" SA_TEST_FILE=<File>.jl julia --project test/runtests.jl`.
   Close every Julia process you start.
4. Commits that change the hot path (loop, step, registry lookups, context reads): note it in the row. The owner
   decides when InteractiveIsing checks and perf runs (`perf/run.jl`) happen; at the latest at the end.
5. Renames or removals that affect what branches still on the old layout need: add a row to
   `REBASE_PLAN_COMPILES.md`.
6. Update the table in §5 in the same commit as the port (status, new hash, notes).
7. When the table is done: run the full tests, update `BRANCHES.md`, and tell the owner. Removing
   `refactor/plan-compiles-old` and its folder is the owner's call.

## 5. Commits

"Old-layout files": files under `src/` that the commit changes, which existed at `4f35d638` and are gone or moved on
`main` (paths under `src/`). An empty cell does not mean the commit is easy: `main` may still have rewritten
the file (`git diff 4f35d638 main -- <file>`).

Status: `open`, `done <new hash>`, `skip`, `squashed into #n`, `asked` (waiting for the owner).

| # | Old | Subject | Old-layout files | Notes | Status |
|---|---|---|---|---|---|
| 1 | `120bec25` | UniquePlanId: Unique handles numbered per plan, held handles stay keys found from types | `InlineProcess.jl`, `InlineProcessShowing.jl`, `Process.jl`, `ProcessInteraction.jl` |  | open |
| 2 | `8e1c19c0` | ProcessContexts: _getindex_by_registry -> _find_subcontext_of (name says what it does) |  |  | open |
| 3 | `fd9407d5` | Vars.jl: _var_match branches with an if and a comment on the stripped-handle case |  |  | open |
| 4 | `3338d7cd` | UniquePlanId in its own folder; Var holds its id as data like Route; lifetimes and RunIf keep their Vars in a field | `Lifetimes/HookExtensions.jl`, `LoopAlgorithms/HookExtensions.jl` |  | open |
| 5 | `c5b5f5d2` | UniquePlanId: a block's state id made stripped; type-only uuids kept by strip; docs for the folder and the hooks |  |  | open |
| 6 | `bae1aa36` | UniquePlanId cleanup: audit fixes |  |  | open |
| 7 | `c91c97a5` | UniquePlanId: the two rewrite modes (strip, number) together in RewriteModes.jl |  |  | open |
| 8 | `94d7c134` | RewriteModes.jl: when each mode runs, a section per mode, inline comments on what each method does |  |  | open |
| 9 | `fb7fa985` | CONDITIONS_EVENTS_DESIGN.md: design decisions for Condition, DSL if/else and OnChange events |  | docs/TODO only | open |
| 10 | `32ee2c69` | LoopAlgorithms/ConstructorCommon.jl: the constructor code shared by composites and routines |  |  | open |
| 11 | `0af3c4f2` | CONDITIONS_EVENTS_DESIGN.md: callback carried by the value, OnChange between steps, AfterMerge, interactive OnRead as considered (not planned) |  | docs/TODO only | open |
| 12 | `2051d4bd` | @Routine docstring: drop the claim that `x = @repeat …` is an error (it is rewritten to a repeated block) |  |  | open |
| 13 | `a90a7861` | Design doc: OnChange fires per merge, OnMutate for in-place writes; ReturnsUpdatesTest comment: `x = @repeat` with @Routine is a repeated block, not an error |  | docs/TODO only | open |
| 14 | `ca4792d6` | UniqueKeyMap in the registry from resolve until the plan is run; no HeldRegistry, no global map cache | `InlineProcess.jl`, `Process.jl`, `ProcessInteraction.jl`, `TimedProcess.jl` |  | open |
| 15 | `620e8ad7` | UserContextCache.jl: cache of the context a process hands to the user (with its UniqueKeyMap put back), per process | `InlineProcess.jl`, `Process.jl`, `ProcessInteraction.jl` |  | open |
| 16 | `20e1cf78` | Revert the user-context cache (UserContextCache.jl): context(p) builds the user's context once when handing it out | `InlineProcess.jl`, `Process.jl`, `ProcessInteraction.jl` |  | open |
| 17 | `1e279969` | The process puts the UniqueKeyMap into the user's context once, at loop exit | `InlineProcess.jl`, `Process.jl`, `ProcessInteraction.jl` |  | open |
| 18 | `827f6ca8` | Rename HeldIds.jl to UniqueKeyMap.jl, after the type it defines |  |  | open |
| 19 | `e937ccc5` | Var holds only its matcher: `Var{M, name, transform}`, `matcher::M`; a context key is a `KeyMatcher{k}` |  |  | open |
| 20 | `2ddd5389` | `Var` of a `Unique` handle, `RunIf` and the condition lifetimes are built untyped: no compile per new handle |  |  | open |
| 21 | `2f0e7af0` | Unique builds its matcher with the UniquePlanId constructor; remove user_unique_id |  |  | open |
| 22 | `b3c6cb20` | `reconstruct_var(V)` and `reconstruct_matcher(M)`: a `Var` and its matcher from the type alone |  |  | open |
| 23 | `5446565b` | A lifetime from outside the plan gets the plan's numbers when it is given (`number_by_keymap`) | `InlineProcess.jl`, `Process.jl`, `ProcessInteraction.jl` |  | open |
| 24 | `4d040669` | ProcessSession: the loop runs on a session, not on the process; the process holds the plan's UniqueKeyMap typed | `AbstractProcesses/Hooks.jl`, `AbstractProcesses/Interface.jl`, `InlineProcess.jl`, `Lifetimes/HookExtensions.jl`, `Process.jl`, `ProcessInteraction.jl`, `ProcessPrecompile.jl`, `ProcessStatus.jl` |  | open |
| 25 | `a122cf81` | Copied processes and manager workers keep the plan's UniqueKeyMap; run(p; lifetime) and a manager's job lifetime number while compiling | `Copy.jl`, `InlineProcess.jl`, `Process.jl`, `ProcessInteraction.jl` |  | open |
| 26 | `428d0797` | TODO.md: sessions, typed map and lifetime numbering; stale process items updated; broken process code outside the loop |  | docs/TODO only | open |
| 27 | `d058948c` | InlineSession keeps no times; loopint cannot throw, so the loop keeps its counter in a register |  |  | open |
| 28 | `b45ba2ad` | InlineSession holds the InlineProcess's context; run_session_loop! reads and writes it there | `InlineProcess.jl` |  | open |
| 29 | `fb15e0a9` | Lifetime Vars get their keys before the loop; run(ip) inlines the loop and is compiled when the InlineProcess is built | `InlineProcess.jl`, `Lifetimes/HookExtensions.jl` |  | open |
| 30 | `99a34d80` | The inline loop is a call again; lifetime Vars get their keys before it; the counter is reset inside it | `InlineProcess.jl`, `Lifetimes/HookExtensions.jl` |  | open |
| 31 | `d8afa544` | Process compiles its first run when built; constructor keyword calls by hand; create_session; TODO 11 closed | `InlineProcess.jl`, `Process.jl`, `ProcessPrecompile.jl` |  | open |
| 32 | `d16a0667` | run(ip; inlined = Val(true)) pastes the loop into run(ip); the default stays a call | `InlineProcess.jl` |  | open |
| 33 | `1a20a56c` | Process compiles its first run's methods in parallel when built (`precompile_in_parallel`) | `ProcessPrecompile.jl` |  | open |
| 34 | `3e408e3a` | precompile_in_parallel's tasks run a `PrecompileJob`, not a closure: one method for every signature | `ProcessPrecompile.jl` |  | open |
| 35 | `620d5c65` | precompile_first_run!: one hook, in src/PrecompileFirstRun.jl, for every process type and the manager | `InlineProcess.jl`, `Process.jl`, `ProcessPrecompile.jl` |  | open |
| 36 | `09d8686e` | precompile_interface: one block of precompile calls per type, in src/PrecompileInterface.jl; the finalizer does not close | `InlineProcess.jl`, `Process.jl`, `ProcessList.jl` |  | open |
| 37 | `518e470c` | precompile_interface tasks capture the process and take its types inside; a Process's `id` is `list_ref` | `Process.jl`, `ProcessInteraction.jl`, `ProcessList.jl` |  | open |
| 38 | `431672ec` | precompile_interface: the types first, then one `precompile` per call |  |  | open |
| 39 | `32034e8b` | Process: a paused run's context in its own field; no `context(p, c)`; `makeloop!` is one call | `Process.jl`, `ProcessInteraction.jl` |  | open |
| 40 | `1f8d93f0` | Keymap getters and setters (getkeymap, with_keymap, strip_keymap, attach/detach_keymap) in UniquePlanId/Accessors.jl |  |  | open |
| 41 | `b50e2c2e` | run(ip) returns its context with the UniqueKeyMap; is_found_by_data is gone | `InlineProcess.jl` |  | open |
| 42 | `32f77cf1` | LookupKey(algo) makes every lookup key; RuntimeLookupKey is gone |  |  | open |
| 43 | `b9b202bf` | TODO: fast path for a plan with one Unique per type |  | docs/TODO only | open |
| 44 | `0b19557a` | TODO (urgent): merge semantics, which states may become one and whether the registry merge should exist |  | docs/TODO only | open |
| 45 | `c7957f13` | DSL: a block's own @state is its first state; no id check |  |  | open |
| 46 | `7b2c5351` | DynamicUnique(f): a Unique with its uuid in the value only, made directly |  |  | open |
| 47 | `9f8670e2` | TODO (merge semantics): is_given_id goes with the registry merge and name matching |  | docs/TODO only | open |
| 48 | `81c72225` | States match by their id, never by name; the registry merges no states; is_given_id is gone |  |  | open |
| 49 | `0d739b0d` | TODO (merge semantics): record what is done |  | docs/TODO only | open |
| 50 | `e3779590` | A handle is statically findable when its matcher is; a UniquePlanId only when numbered |  |  | open |
| 51 | `064238e3` | The lifetime's condition and its read of the context are inlined where they are called | `Lifetimes/HookExtensions.jl` |  | open |
| 52 | `38cedb3d` | unwrap_named_plan: readable docstring |  |  | open |
| 53 | `5eea0a63` | Edit: public edit functions in Edit.jl, their helpers in Edit/Backend.jl |  |  | open |
| 54 | `5f002505` | Rename the typed keymap functions: with_keymap_typed, strip_keymap_typed | `InlineProcess.jl` |  | open |
| 55 | `f4865944` | Registry builder: the walk on values finds the same algorithm with `match` |  |  | open |
| 56 | `3fcbaf7c` | Registry builder: the walk on types also finds the same algorithm with `match` |  |  | open |
| 57 | `ca5b1d10` | TODO: GeneralState.jl cleanup, details in agents/general-state-cleanup.md |  | docs/TODO only | open |
| 58 | `b21615e9` | TODO: Process files folder layout and InlineProcess cleanup (agents/process-files-cleanup.md) |  | docs/TODO only | open |
| 59 | `6b490378` | _step!: drop @constprop :aggressive; every argument's information is in its type |  |  | open |
| 60 | `1067dff9` | Registry lookups: one inlined body through `match`; `match` decides types or `==` |  |  | open |
| 61 | `c352f70b` | Process files TODO: Manager/ stays where it is |  | docs/TODO only | open |
| 62 | `762ec4e1` | Comments and internals docs: a named state's name is only its key; @merge takes whole states |  |  | open |
| 63 | `64a5a6c3` | Process files TODO: keep TimedProcess, move it and bring its API up to the others |  | docs/TODO only | open |
| 64 | `33c96bd7` | Process files TODO: TimedProcess on a session; where its UniqueKeyMap comes from |  | docs/TODO only | open |
| 65 | `bc86e552` | Process files TODO: TimedProcess works the same way as Process |  | docs/TODO only | open |
| 66 | `918c1c84` | Internals docs: process pipeline from plan to loop and back; why processes run through sessions |  | docs/TODO only | open |
| 67 | `4ce27656` | UniquePlanId: `:dynamic` form, `==` decides static first; ids stay dynamic until resolve; match without a trait |  |  | open |
| 68 | `a423a0ae` | TODO: code that works around the matching system, grouped |  | docs/TODO only | open |
| 69 | `02a3bdda` | Numbering walk: keep what it works out from types between calls |  |  | open |
| 70 | `1cf50107` | Plan constructor parses its arguments untyped, in one Vector{Any} |  |  | open |
| 71 | `39c66f7e` | dynamic_match: an untyped match for the registry walk, its matchers compared with dynamic_equals |  |  | open |
| 72 | `ef069de0` | matcher_equals: matchers compare through a package function, not Base.:(==) |  |  | open |
| 73 | `235b081b` | findfirst_unspecialized(f, items, args...): f(item, args...), any number of extra arguments |  |  | open |
| 74 | `bd39c32b` | Comment out IndentIO: unused, and its print/println methods invalidated Base's printing on load |  |  | open |
| 75 | `4933556b` | A handle's match_by and id compile once; the registry's multipliers are collected untyped |  |  | open |
| 76 | `40964c41` | Construction compiles nothing per plan type: untyped wrapping, splitting, locals; structs made with new_instance |  |  | open |
| 77 | `9aff26b8` | Constructor keeps its kept intervals without a filtered comprehension |  |  | open |
| 78 | `b3bfa382` | Resolve compiles once: untyped entries, step 3 wiring with vectors, callable names from types as values |  |  | open |
| 79 | `88d2bf22` | Resolve finds route and share endpoints on values: dynamic_resolve_scref, registry lookups with dynamic_match |  |  | open |
| 80 | `4ace8b5b` | No caches: the id walk and _field_parameter_index work out their type facts per call |  |  | open |
| 81 | `865a21ca` | Plain loops instead of closures: parse_la_input's options check, the typed scope generators |  |  | open |
| 82 | `e2bbfd83` | The UniqueKeyMap lives only in the registry: processes hold no map of their own | `Copy.jl`, `InlineProcess.jl`, `Process.jl`, `ProcessInteraction.jl` |  | open |
| 83 | `e7149b6f` | One Partition{kind, name} for where a value lives; locations carry it | `Context/ContextBundles.jl`, `Context/View/ReadingWriting.jl` | twin on `refactor/partitions` | open |
| 84 | `9dd56a5d` | Partition lives in StructDefs.jl; ContextPartitions.jl removed |  | twin on `refactor/partitions` | open |
| 85 | `c817e120` | No session holds the context: an InlineProcess passes its context to the loop as an argument | `InlineProcess.jl` |  | open |
| 86 | `849b2ac6` | The map is dropped where a run is handed to the loop: manager's inline run and TimedProcess too | `TimedProcess.jl` |  | open |
| 87 | `76e12461` | Comments and docs: no session holds the context; the map only in the plan's registry | `InlineProcess.jl`, `Process.jl` |  | open |
| 88 | `ea206e5d` | lower_type keeps nothing between calls: the LOWERED_TYPES cache is gone |  |  | open |
| 89 | `d34c7d34` | Bring IndentIO back: InteractiveIsing uses it; TODO to move it out or make it not invalidate Base |  | docs/TODO only | open |
| 90 | `7556f618` | TODO: the loop returns the context twice; cleanup/@finally per run is the open question first |  | docs/TODO only | open |
| 91 | `05178f89` | run(ip; inlined): current numbers (context not passed into a call and back: 57-62 vs 121-150 ns; first-run compile per handle set) | `InlineProcess.jl` |  | open |
| 92 | `6ba54ffe` | The run builds the LoopContext: loop_context(plan, context, inputs, resume) at the hand-off, the loop takes it | `InlineProcess.jl`, `Process.jl` |  | open |
| 93 | `9b7e6e15` | LoopContext(plan, context, inputs, resume) is the one entry: it drops the map and checks the inputs | `Context/ContextBundles.jl`, `InlineProcess.jl`, `Process.jl` |  | open |
| 94 | `6eb222d0` | LoopContext(plan, context, inputs, resume) is generated: its type is worked out from the argument types | `Context/ContextBundles.jl` |  | open |
| 95 | `83f47323` | LoopContext constructor: plain again, not specialized on the context | `Context/ContextBundles.jl` |  | open |
| 96 | `f274b85e` | prepare_loop(owner, inputs, lifetime, resume) -> (session, plan, loop_context): the first call of every run | `AbstractProcesses/Hooks.jl`, `InlineProcess.jl`, `LoopAlgorithms/HookExtensions.jl`, `Process.jl` |  | open |
| 97 | `647ec5f3` | Doc: user handles and loop versions (process -> session, plan -> loop plan, context -> LoopContext); TODOs | `LoopAlgorithms/HookExtensions.jl` |  | open |
| 98 | `a6a05053` | TODO: run(plan) untyped at its entry; make it typed with the map dropped in prepare_loop |  | docs/TODO only | open |
| 99 | `d53f9621` | InlineProcess: no threaded mode; async is run(ip; async = Val(true)) | `InlineProcess.jl`, `InlineProcessShowing.jl` |  | open |
| 100 | `8f388b42` | Var is an unresolved VarLocation: one location type |  | twin on `refactor/partitions` | open |
| 101 | `641ee2c2` | Resolved locations hold no matcher: a Var resolves to VarLocation{StatePartition{key}}; KeyMatcher removed |  |  | open |
| 102 | `9fbc9694` | resolve_var_key(s) renamed resolve_var(s): a Var resolves to its location, not to a key | `InlineProcess.jl`, `Lifetimes/HookExtensions.jl` |  | open |
| 103 | `1d70d374` | SCRef -> nsref (resolved through the registry to a namespace) and partref (a slot that names a part of the context) |  | twin on `refactor/partitions` | open |
| 104 | `a428f9fe` | TODO: name the branch the one-getproperty item was done on (refactor/plan-compiles) |  | docs/TODO only | open |
| 105 | `13ef0497` | Remove getindex(::SubContext, ::Var...): it recursed forever on one Var and had no caller |  |  | open |
| 106 | `6830c9d1` | partition_name is not specialized: compiled once for every partition, still folded to a constant |  | twin on `refactor/partitions` | open |
