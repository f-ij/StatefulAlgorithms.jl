# What `refactor/plan-compiles-old` adds and removes again

Made 2026-11-05 for the rebuild (REBUILD_PLAN_COMPILES.md). The owner's rule: anything the old branch introduces and
later deletes or replaces is not ported; port the replacement when its commit comes. Scanned from the tip `6830c9d1`
backwards against the base `4f35d638`, by three agents (commits #1-36, #37-72, #73-106; numbers as in
REBUILD_PLAN_COMPILES.md §5), every name checked with `git grep` at the tip. Only items new on the branch are listed;
things that existed at the base are not.

## 1. Already ported before this doc existed (2026-11-05)

These came in with #1-#23 and are, or will be, removed by a later row:

| Item | Ported in | Removed by (old) | Status on the rebuild |
|---|---|---|---|
| `HeldRegistry`, `with_held_ids`, `strip_held_ids`, `_KEY_MAPS`/`cached_key_map` | #1 | #14 | gone since #14 |
| `_var_match` | #1 | #4 | gone since #4 |
| `strip_uniques`, `user_unique_id` | #1 | #6, #21 | gone |
| `Process.keymap`, `InlineProcess.keymap`, `TimedProcess.keymap` (fields) | #14 | #82 | removed in `f808cc8d`: the map lives only in registries |
| `user_context` fields, `set_user_context!` | #17 | #82 | removed in `f808cc8d` |
| `ValueId` | #4 | #67 | still in; goes with #67 |
| `is_found_by_data` (hook) | #4 | #41 | still in; goes with #41 |
| `_is_merged_id`, `is_given_id` | #6, #4 | #48 | still in; go with #48 |
| `KeyMatcher{key}`; `Var` as its own struct (`matcher` field) | #19 | #101, #100 | still in; go with #100/#101 |
| `list_field_derived_params` returns `(param, field, derive)` specs | #4 | survives at the old tip; deleted by `9d5c7936` (one function replaces the ids in a value, no such hook) | removed with row #107 (`9d5c7936`, moved from monolithic-resolve, 2026-11-06) |

## 2. Not to port (introduced and removed again on the old branch)

### Commits #1-#36

| Introduced | Item | Where | Removed/replaced by | Replaced with |
|---|---|---|---|---|
| #1 `120bec25` | `src/Identifiable/UniquePlanIds.jl` (file) | src/Identifiable/ | #4 `3338d7cd` | folder `UniquePlanId/` |
| #1 `120bec25` | `_var_match` | Context/Vars.jl | #4 `3338d7cd` | `Var` holds the matcher as data |
| #1 `120bec25` | `UniquePlanId{nothing}` as stripped form | UniquePlanIds.jl | #4 `3338d7cd` | `UniquePlanId{ValueId}`, from #67 `:dynamic` |
| #1 `120bec25` | `rewrite_param`, `rewrite_type_number` | UniquePlanIds.jl | #4 `3338d7cd` | `_rebuilt_params`, `rewrite_type_id` |
| #1 `120bec25` | `_number!`, `_collect_unique_ids!`, `_collect_type_ids!`, `_scope_numbers!`; `_NumberIds.scope`/`.fallback` | UniquePlanIds.jl | #4 `3338d7cd` | one pass, `_NumberIds.numbers` |
| #1 `120bec25` | `_number_plan_unique_ids`, `_is_nested_plan_input` | LoopAlgorithms/Setup.jl | #4 `3338d7cd` | `number_unique_ids((funcs, states, options, schedule))` |
| #1 `120bec25` | `_is_given_id` (hook `is_given_id` from #4) | Registry/Interfaces.jl | #48 `81c72225` | states match only by id |
| #1 `120bec25` | `strip_uniques` | UniquePlanIds.jl | #6 `bae1aa36` | `strip_unique` on the tuple |
| #1 `120bec25` | `user_unique_id` | UniquePlanIds.jl | #21 `2f0e7af0` | `UniquePlanId(uuid4())` |
| #1 `120bec25` | `HeldRegistry`, `with_held_ids`, `strip_held_ids`, `_KEY_MAPS`, `cached_key_map` | UniquePlanIds.jl | #14 `ca4792d6` | map in `NameSpaceRegistry.keymap` |
| #1 `120bec25` | `_HeldContextCache`, `Process.held_keymap` | Process.jl | #14 / #82 | map only in the plan's registry |
| #1 `120bec25` | `_scref_identity` | SubContextRefs.jl | #67 `4ce27656` | `same_scref` via `match` |
| #4 `3338d7cd` | `UniquePlanId/Number.jl`, `Strip.jl` | UniquePlanId/ | #7 `c91c97a5` | `RewriteModes.jl` |
| #4 `3338d7cd` | `ValueId` | UniquePlanId/StructDef.jl | #67 `4ce27656` | `UniquePlanId{:dynamic}` / `DynamicPlanId` |
| #4 `3338d7cd` | `is_found_by_data` (hook) | Registry/Interfaces.jl | #41 `b50e2c2e` | no runtime uuid fallback |
| #4 `3338d7cd` | `scref_data`; `Var.data` field, `D` param | SubContextRefs.jl, Vars.jl | #19 `e937ccc5` | `Var{M,name,transform}`, `matcher::M` |
| #6 `bae1aa36` | `_is_merged_id` | AlgoStates/GeneralState.jl | #48 `81c72225` | states match by id |
| #14 `ca4792d6` | `Process.keymap`, `InlineProcess.keymap` (typed `K` from #24) | Process.jl, InlineProcess.jl | #82 `e2bbfd83` | map only in the plan's registry |
| #15 `620e8ad7` | `UserContextCache.jl`, `BuiltUserContext`, `USER_CONTEXT_CACHE`, `get_user_context` | UniquePlanId/ | #16 `20e1cf78` | reverted |
| #17 `1e279969` | `InlineProcess.user_context`, `Process.user_context`, `set_user_context!`, `with_process_keymap` | InlineProcess.jl, Process.jl | #24 / #82 | map only in the registry |
| #19 `e937ccc5` | `KeyMatcher{key}` | Matching.jl | #101 `641ee2c2` | `VarLocation{StatePartition{key}}` |
| #19 `e937ccc5` | `Var` struct with `matcher` field | Context/Vars.jl | #100 `8f388b42` | `const Var{M,...} = VarLocation{M,...}` |
| #23 `5446565b` | `_run_process` | ProcessInteraction.jl | #25 `a122cf81` | typed `run(p)` numbering the lifetime |
| #24 `4d040669` | `UniquePlanId/ContextKeymap.jl` | UniquePlanId/ | #40 `1f8d93f0` | `UniquePlanId/Accessors.jl` |
| #24 `4d040669` | `InlineSession.starttime`/`.endtime` | Sessions/InlineSession.jl | #27 `d058948c` | no times |
| #25 `a122cf81` | `getalgo_with_keymap` | Process.jl | #82 `e2bbfd83` | `getalgo(p)` carries the map |
| #28 `b45ba2ad` | `InlineSession.context` + `C`; `run_session_loop!` | Sessions/InlineSession.jl, Loops.jl | #85 `c817e120` | context passed to the loop as an argument |
| #31 `d8afa544` | `_precompile_process!` | ProcessPrecompile.jl | #35 / #36 | `precompile_interface` |
| #31 `d8afa544` | `ProcessTaskBody.runtime_context`/`.inputs`, params `C`, `I` | Process.jl | #92 `6ba54ffe` | `loop_context` field |
| #32 `d16a0667` | `run_session_loop_body!` | Loops.jl | #85 `c817e120` | `@inline loop(...)` in `_run_inline!` |
| #33 `1a20a56c` | `precompile_in_parallel` | ProcessPrecompile.jl | #36 `09d8686e` | spawns inside `precompile_interface` |
| #34 `3e408e3a` | `PrecompileJob` | ProcessPrecompile.jl | #36 `09d8686e` | `Vector{Any}` of signatures |
| #35 `620d5c65` | `src/PrecompileFirstRun.jl`, `precompile_first_run!` | src/ | #36 `09d8686e` | `precompile_interface(x)` |

### Commits #37-#72

| Introduced | Item | Where | Removed/replaced by | Replaced with |
|---|---|---|---|---|
| #41 `b50e2c2e` | `user_registry::UR` field + type param `UR` on `InlineProcess` | src/InlineProcess.jl | #82 `e2bbfd83` | process holds no map; `algo` = plan whose registry holds the map; `loop_algo` field; user context via `with_plan_registry` |
| #41 `b50e2c2e` | `attach_user_registry(ip, x)` (renamed `with_user_registry` #54) | src/InlineProcess.jl | #82 `e2bbfd83` | `with_plan_registry(ip, x)` |
| #41 `b50e2c2e` | `set_session_context!(ip, c)` | src/InlineProcess.jl | #85 `c817e120` | no session holds the context; `set_loop_context!` writes `ip.context` |
| #50 `e3779590` | `isstaticallyfindable(::UniquePlanId)`, `isstaticallyfindable(::IdentifiableAlgo)` | UniquePlanId/HookExtensions.jl, Registry/Findability.jl | #67 `4ce27656` | trait removed (Findability.jl gone); `match` compares matchers |
| #52 `38cedb3d` | SA dep + `[sources]` in test/Project.toml (+ test/Manifest.toml) | test/ | #53 `5eea0a63` | reverted |
| #55 `f4865944` | walk on values: `findfirst(other -> match(algo, other), ...)` | Registry/Builder.jl | #71/#72 | `findfirst_unspecialized(dynamic_match, entry.algos, algo)` |
| #56 `3fcbaf7c` | walk on types: closure calling `match` | Registry/Builder.jl | #71 `39c66f7e` | same closure calling `dynamic_match` |
| #60 `1067dff9` | `match` body via `isstaticallyfindable`/`static_id` + AbstractMatcher passthrough | Matching.jl | #67 `4ce27656` | `match_by(a) == match_by(b)`, then `matcher_equals` (#72) |
| #67 `4ce27656` | inline `==(::UniquePlanId{N1}, ::UniquePlanId{N2})` body | UniquePlanId/StructDef.jl | #71 `39c66f7e` | `same_unique_id(N1,N2,a,b)` (the `==` method survives) |
| #67 `4ce27656` | `same_scref` as 4 dispatch methods | SubContextRefs.jl | #103 `1d70d374` | renamed `same_nsref` |
| #69 `02a3bdda` | `_UNIQUE_IDS_TYPE_CACHE` + lock (global cache) | UniquePlanId/Rewrite.jl | #80 `4ace8b5b` | fresh `IdDict` per call |
| #69 `02a3bdda` | `_FIELD_PARAMETER_INDICES` + lock, `_field_parameter_indices` | Functions.jl | #80 `4ace8b5b` | per-call loop in `_field_parameter_index` |
| #70 `1cf50107` | filtered comprehension for kept intervals | ConstructorCommon.jl | #77 `9aff26b8` | plain loop with `push!` |
| #70 `1cf50107` | `all(x -> ..., rest)` options check | ConstructorCommon.jl | #81 `865a21ca` | plain `for` loop |
| #71 `39c66f7e` | `findfirst(other -> dynamic_match(...))` | Registry/Builder.jl | #72 `ef069de0` | `findfirst_unspecialized` |
| #72 `ef069de0` | `findfirst_unspecialized(f, x, items)` argument order | Utils.jl | #73 `235b081b` | `findfirst_unspecialized(f, items, args...)` |


### Commits #73-#106
| Introduced | Item | Where | Removed/replaced by | Replaced with |
|---|---|---|---|---|
| #74 `bd39c32b` | `IndentIO` commented out | src/Printing.jl | #88 `ea206e5d` / #89 `d34c7d34` | IndentIO active again, with a TODO |
| #82 `e2bbfd83` | `InlineSession{C, A}` param `A`, field `algo`; `InlineSession(context, algo)` | Sessions/InlineSession.jl | #85 `c817e120` | `InlineProcess.loop_algo`/`context`; `InlineSession()` counter only |
| #82 `e2bbfd83` | typed `session::InlineSession{ContextType, A}` on InlineProcess | InlineProcess.jl | #85 `c817e120` | untyped `session::InlineSession` |
| #82 `e2bbfd83` | 5-arg `_makeloop!(p, inputs, lt, loop_context, func)`; strip_keymap in `makeloop!` | Process.jl | #93, #96 | `prepare_loop` -> `_makeloop!(p, session, func, lc, lt)`; map dropped in `LoopContext(plan, context, inputs, resume)` |
| #92 `6ba54ffe` | `loop_context(algo, ctx, inputs, resume)` | Loops.jl | #93 `9b7e6e15` | `LoopContext(plan, context, inputs, resume)` |
| #93 `9b7e6e15` | `LoopContext` typed on `C` with `strip_keymap_typed` | ContextBundles.jl | #94, #95 `83f47323` | `@nospecialize(context)` + `has_keymap(c) ? strip_keymap(c) : c` |
| #93 `9b7e6e15` | `_makeloop!(p, lt, func, lc)` signature | Process.jl | #96 `f274b85e` | `prepare_loop` -> `_makeloop!(p, session, func, lc, lt)` |
| #93 `9b7e6e15` | `_run_plan` puts the map back with `with_keymap_typed` | RuntimeInputs.jl | #97 `647ec5f3` | `run(plan)` strips at entry, `with_keymap`s the result |
| #93 `9b7e6e15` | `LCArgs` precompile pattern | PrecompileInterface.jl | #95 `83f47323` | `return_type(LoopContext, Tuple{...})` + plain precompile |
| #94 `6eb222d0` | file `Context/LoopContextConstructor.jl`, `@generated LoopContext`, helpers `_loop_algorithm_at`, `_runtime_input_specs_at`, `_checked_inputs_at`, `_without_keymap_at`, `_runtime_context_at`, `_resumed_contexts_at` | LoopContextConstructor.jl | #95 `83f47323` | plain constructor in ContextBundles.jl |
| #94 `6eb222d0` | `_tree_locals!` | LoopAlgorithms/Locals/Locals.jl | #95 `83f47323` | the earlier `collect!` closure restored |

### Process-level `UniqueKeyMap` pieces removed by #82 and #85-#96 (any commit)
| Introduced | Item | Where | Removed/replaced by | Replaced with |
|---|---|---|---|---|
| #1 `120bec25` (`held_keymap`), #14 `ca4792d6` (`keymap::Any`), #24 `4d040669` (typed `K`) | `Process.keymap` field + type param `K` | Process.jl | #82 `e2bbfd83` | `Process{F,C}`; map only in `p.algo`'s registry (`getkeymap(getalgo(p))`) |
| #14, #24 | `InlineProcess.keymap` field + `K` | InlineProcess.jl | #82 `e2bbfd83` | `ip.algo` holds the plan with the map in its registry |
| #17 `1e279969` | `Process.user_context` field, `set_user_context!`, `with_process_keymap` | Process.jl | #82 `e2bbfd83` | `context(p) = _context(p)`; stored contexts have the plan's registry; `with_plan_registry(p, x)` |
| #24 `4d040669` | `keymap`/`user_context` in `@setterGetter Process` | Process.jl | #82 | removed |
| #25 `a122cf81` | `getalgo_with_keymap(p)` | Process.jl | #82 | `getalgo(p)` carries the map |
| #41 `b50e2c2e` | `InlineProcess.user_registry` + `UR`; `attach_user_registry`/`with_user_registry` | InlineProcess.jl | #82 | `with_plan_registry(ip, c)` |
| #24 | `keymap` argument of `_construct_process` / `_construct_inline_process` | Process.jl, InlineProcess.jl | #82 | `_construct_process(with_keymap(algo, keymap), ...)` |
| #24, #25 | `getfield(p, :keymap)` reads (lifetimes, manager, tests) | several | #82 | `getkeymap(getalgo(p))` |
| #28 `b45ba2ad` | `InlineSession{C}` with field `context`; `run_session_loop!(session, algo, lifetime, inputs)` | Sessions/InlineSession.jl, Loops.jl | #85 `c817e120` | `InlineProcess.context` passed to the loop; `run_session_loop(loop, session, algo, context, ...)` |
| #41 | `set_session_context!(ip, c)` | InlineProcess.jl | #85 | `set_loop_context!(ip, c)` writes `ip.context` |
| `d16a0667` (#32) | `run_session_loop_body!` | Loops.jl | #85 | `@inline loop(...)` in `_run_inline!` |
| #14 | TimedProcess strips at entry and keeps no map | TimedProcess.jl | #86 `849b2ac6` | `tp.algo`/`tp.context` keep the map; step callback gets the stripped plan |

Renamed, survives: dynamic_resolve_scref -> dynamic_resolve_nsref, _dynamic_object_sckey -> _dynamic_object_namespace_key (#103); set_session_context! -> set_loop_context! (#85). Survive at tip: with_plan_registry, _cleanup_paused_context (#82); InlineProcess loop_algo/context (#85); _timed_step_callback (#86); has_keymap, _add_runtime_input_defaults (#95); prepare_loop (#96); resolve_var(s) (#102); nsref/partref (#103).
Notes: #94 deleted _validate_runtime_inputs/_runtime_input_defaults, #95 restored them (base items).


## 3. Renamed, survives (port under the final name when the rename's row comes)

`_getindex_by_registry` -> `_find_subcontext_of` (#2); `scref_derived_params` -> `list_field_derived_params` (#4);
`HeldIds.jl` -> `UniqueKeyMap.jl` (#18); `_inline_run_context` -> `_set_inline_run_context!` (#28);
`_session_for_run!` -> `create_session` (#31); `Process.id` -> `list_ref` (#37); `attach_keymap`/`detach_keymap` ->
`with_keymap_typed`/`strip_keymap_typed` (#40, #54); `_composite_dsl_is_block_state` -> `_composite_dsl_is_general_state`
(#45); `set_session_context!` -> `set_loop_context!` (#85); `resolve_var_key(s)` -> `resolve_var(s)` (#102); `same_scref`
-> `same_nsref`, `scref_matcher` -> `nsref_matcher`, `dynamic_resolve_scref` -> `dynamic_resolve_nsref`,
`_dynamic_object_sckey` -> `_dynamic_object_namespace_key` (#103).

## 4. Notes

1. #52 adds `include("Backend.jl")` before #53 creates the file, and its test-project change is reverted by #53: port
   #52 and #53 as one.
2. #94 deletes `_validate_runtime_inputs`/`_runtime_input_defaults` and #95 restores them; #94's whole generated
   `LoopContext` is replaced by #95: port the pair as #95.
3. Method-level changes of functions that existed at the base are not compared method by method; test-only helpers are
   not covered.
