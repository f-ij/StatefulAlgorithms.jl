# Index of `Base.@nospecializeinfer` blocks

Made 2026-11-07 on `refactor/plan-compiles` (at `7be74085`) from the audit of 2026-11-06; the TODO item "Walk the `@nospecializeinfer` blocks" (TODO.md) refers here. Functions are listed by file and name; line numbers drift on this branch, grep the name.

## What the block does

`Base.@nospecializeinfer` only acts on the arguments marked `@nospecialize`. `@nospecialize` alone compiles one machine-code body for all argument types, but a caller whose argument types are known still makes Julia infer the function again for those types. The block stops that: the function is inferred once, for the declared types. The price: that caller only gets the return type the declared types give (often `Any`). So the block helps only where a caller knows the argument types (column "callers" = typed or generator) and nothing after the call needs a precise result.

## Measured so far (2026-11-06, fresh processes, min of 3, interleaved)

1. The 6 blocks on functions without a `@nospecialize` argument were removed in `d2d9ee0b`: same compiled-method count and compile times.
2. Test only, not proposed: removing every block gave +7% compiled methods of the package (+19 to 21% on the DSL and `Unique` workloads) and 6 to 11% longer first runs of a plan; warm construction and run times unchanged. So the blocks together are worth keeping; the walk is about the single blocks that do nothing.
3. `run(plan, context)`, `init(plan, context, ...)`, `prepare_for_loop`: unblocking them made a fresh `Unique` build compile 23 ms -> 27 ms, warm `run` 0.6 us and `init` 0.2 us unchanged. Keep.
4. `precompile_interface(::InlineProcess)`: unblocked, +30 compiled methods on the combined workload. Keep.

## How to walk

Remove the blocks of one group at a time (by file group, starting with "untyped only" and "dispatch only" rows), count the compiled methods of the package after the combined workload and compare with the count before; one comparison at a time. A group that changes nothing: remove its blocks. A group that changes the count: split it and repeat. Workload and scripts of 2026-11-06 (session scratchpad, may be gone): plans of perf/compile.jl (nested composite, Routine in Routine with repeats, route, DSL block), three builds with fresh `Unique` handles under `InlineProcess` and `Process`, `setup`/`run`/`init`, and a held `Unique` handle in a `Route` and an `Until(Var(...))` lifetime; count = `Base.specializations` of every method of the package. Not covered by that workload: `Package`/`setup_registry`, the Edit API, multi-plan `resolve`.

## Columns

- **@nospecialize arguments**: the arguments the block acts on.
- **callers** (from reading every caller, 2026-11-06): *typed* = some caller knows the argument types, so the block can save inference; *generator* = called while generating code, once per plan, `Callable` or handle type; *dispatch only* = reached only through run-time dispatch from untyped code, the block can change nothing; *untyped only* = every caller already passes untyped values (`Any`, `Vector{Any}`), the block changes nothing today and only guards against a later typed caller.
- **note**: which typed caller, and measurements.

Totals: 158 blocks; dispatch only 9, generator 13, typed 55, untyped only 81.

### src/CompositeDSL/StateAndRoutes.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_composite_dsl_map_state_entries` | entries | untyped only |  |
| `_composite_dsl_map_state_children` | children | untyped only |  |
| `_composite_dsl_map_states_changed` | entity | untyped only |  |
| `_composite_dsl_map_states` | entity | untyped only |  |
| `_composite_dsl_prefix_state_diagnostic_paths` | entity | untyped only |  |

### src/ConstructorCommon.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `construction_error` | parts | typed | typed error paths (PlanOptions, RouteDef); always throws |
| `construction_assert_error` | parts | typed | typed error paths; always throws |

### src/Context/Vars.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `Var` | subcontext_ref | typed | user code with a Unique handle (new type per uuid); result Any via new_instance |

### src/Functions.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_field_parameter_index` | T | untyped only |  |

### src/GeneratedCode/Registry/Expressions.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `build_from_parts` | T | generator |  |
| `write_struct_expr` | T | generator |  |
| `collect_multipliers` | multipliers | typed | spliced into the generated registry setup; result always Vector{Float64} |
| `lookup_table` | keys, idxs | generator |  |

### src/Identifiable/Constructors.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `IdentifiableAlgo` | f | typed | Autokey, DSL owner code, edit backend (typed per algorithm type); result Any |
| `IdentifiableAlgo` | f | typed | Autokey, DSL owner code, edit backend (typed per algorithm type); result Any |
| `IdentifiableAlgo` | f, (unnamed) | typed | Autokey, DSL owner code, edit backend (typed per algorithm type); result Any |
| `Unique` | f | typed | user code (typed per algorithm type); result Any |
| `DynamicUnique` | f | typed | DSL block code (typed per state type); result Any |
| `unique_with_id` | f, id | untyped only |  |

### src/Identifiable/HookExtensions.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `rebuild_with_fields` | sa | dispatch only |  |

### src/Identifiable/IdentifiableAlgos.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `setcontextkey` | sa | typed | typed per handle type (IdentifiableAlgo(na, name), Autokey, replacecontextkeys); result Any |

### src/Identifiable/StructDef.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `identifiable_with_id` | func, id, aliases, algoname, key | untyped only |  |
| `setmatcher` | sa, id | typed | setid (typed per handle type); setid on a handle has no caller found |

### src/Identifiable/UniquePlanId/Accessors.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_registry_field` | x | untyped only |  |
| `with_keymap` | x, keymap | typed | process constructors and resolve; result Any |
| `strip_keymap` | x | typed | prepare_for_loop(::InteractiveProcess), _init_process_context, cleanup, _setup (typed per process/context type); result Any |
| `getkeymap` | x | typed | process constructors, setup/init; measured by an agent: unblocked, callers infer one keymap type per set of Unique handles |

### src/Identifiable/UniquePlanId/Hooks.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `rebuild_with_fields` | x | dispatch only |  |
| `_params_from_fields` | T | untyped only |  |

### src/Identifiable/UniquePlanId/ReplaceIds.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `type_mentions_unique_ids` | T | untyped only |  |
| `replace_ids_in_type` | T | generator |  |
| `replace_unique_ids` | x | untyped only |  |
| `read_path` | x, path | untyped only |  |
| `_rebuild_along` | v | untyped only |  |
| `unique_id_locations` | T | generator |  |
| `_collect_locations!` | T, path | untyped only |  |

### src/Identifiable/UniquePlanId/ReplaceModes.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `strip_unique` | x | typed | DSL block code; result Any |
| `number_unique_ids` | x | typed | multi-plan resolve (typed per plan types) |
| `number_by_keymap_dynamic` | x, keymap | typed | spliced into the generated number_by_keymap fallback |

### src/Identifiable/UniquePlanId/StructDef.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `dynamic_equals` | a, b | dispatch only |  |

### src/Identifiable/UniquePlanId/UniqueKeyMap.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `unique_key_map` | reg | typed | multi-plan resolve (typed) |

### src/Lifetimes/AtLeast.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `AtLeast` | cond, vars | typed | same as Until |

### src/Lifetimes/AtLeastAtMost.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `AtLeastAtMost` | cond, vars | typed | same as Until |

### src/Lifetimes/RepeatOrUntil.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `RepeatOrUntil` | cond, vars | typed | same as Until |

### src/Lifetimes/Until.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `Until` | cond, vars | typed | user code, DSL (typed; new type per uuid with a Var); result Any |

### src/LoopAlgorithms/Callable/Signature.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `callable_input_names` | T | generator |  |
| `callable_return_names` | T | generator |  |
| `_returns_parts` | R | generator |  |

### src/LoopAlgorithms/CompositeAlgorithms.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `CompositeAlgorithm` | args | typed | user code, parse_plan (typed); result Any |

### src/LoopAlgorithms/ConstructorCommon.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `LoopAlgorithm` | funcs, states, options, schedule | typed | _rebuild_loopalgorithm from the Edit API (typed per plan type); result Any |
| `_build_plan` | funcs, states, options, schedule | untyped only |  |
| `_parse_loopalgorithm_entity_input` | el | untyped only |  |
| `_normalize_loopalgorithm_entity_input` | el | untyped only |  |
| `parse_la_input` | args | untyped only |  |

### src/LoopAlgorithms/DirectRuns.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `setup` | plan_spec, specs | typed | user code (typed per plan type) |
| `Base.run` | plan, context | typed | user code; MEASURED 2026-11-06: unblocking run/init/prepare_for_loop made a fresh Unique build compile 23 -> 27 ms, warm run unchanged (0.6 us) |
| `init` | plan, context, specs | typed | user code; MEASURED with Base.run (keep) |
| `prepare_for_loop` | plan, context | typed | only from run(plan, context); MEASURED with Base.run (keep) |

### src/LoopAlgorithms/FinalizedAlgorithm/FinalizedAlgorithm.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_strip_nested_finalized_algorithm` | algo | untyped only |  |
| `_strip_nested_finalized_algorithm` | pair | untyped only |  |

### src/LoopAlgorithms/Fusing/Fusing.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `flatten_comp_funcs` | funcs, _intervals | typed | _dsl_build_loopalgorithm, flatten(::CompositeAlgorithm) (typed, but argument tuples are abstract) |
| `_flatten_comp_funcs!` | funcs, _intervals | untyped only |  |
| `_flattens_into_parent` | el | untyped only |  |

### src/LoopAlgorithms/Interface.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `rebuild_plan` | plan, funcs, wiring | untyped only |  |
| `replace_fields` | s, values | untyped only |  |

### src/LoopAlgorithms/Interval.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `RunIf` | cond, vars | typed | user code and DSL schedules; Vars of a Unique handle are a new type per uuid; result Any |
| `RunIf` | interval, cond, vars | typed | user code and DSL schedules; Vars of a Unique handle are a new type per uuid; result Any |
| `RunIf` | cond, vars | typed | user code and DSL schedules; Vars of a Unique handle are a new type per uuid; result Any |

### src/LoopAlgorithms/Locals/Locals.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `collect_plan_locals_untyped` | options | untyped only |  |

### src/LoopAlgorithms/ParameterReplacement.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `store_single_repeats_as_repeat_once` | PlanType, schedule | untyped only |  |
| `setschedule` | plan, schedule | typed | setrepeats/setintervals/setinterval (user API, typed); result Any |

### src/LoopAlgorithms/PlanOptions.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_unwrap_with_wiring` | w | typed | map in _split_children_and_wiring (typed caller is the unused _build_plan_typed) |
| `_append_withwiring_wires` | w, bucket | typed | map in _split_children_and_wiring (same) |
| `_local_wiring_matches_child` | child, option | untyped only |  |
| `_build_child_wiring` | funcs, options | typed | setwiring(::CompositeAlgorithm/::Routine) (typed) |
| `_build_plan_wiring_untyped` | options | untyped only |  |
| `_new_wiring` | routes, shares | untyped only |  |
| `_split_children_and_wiring_untyped` | funcs, options | untyped only |  |
| `_drop_wiring_options_untyped` | options | untyped only |  |
| `_collect_root_options_untyped` | la | untyped only |  |
| `_append_root_options!` | la | untyped only |  |

### src/LoopAlgorithms/Resolving/Registering.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `register_child!` | child, multiplier | untyped only |  |
| `unwrap_named_plan` | child | untyped only |  |
| `read_children` | la | untyped only |  |
| `read_states` | la | untyped only |  |
| `read_multipliers` | la | untyped only |  |
| `build_registry_from_values` | la | typed | spliced into the generated build_registry_and_key_plan (value fallback) |
| `generate_registry_setup` | LA | generator |  |
| `register_tree!` | la | untyped only |  |
| `register_states!` | la | untyped only |  |
| `register_children!` | node, multiplier | untyped only |  |

### src/LoopAlgorithms/Resolving/Resolving.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_build_shared_registry_and_key_plans` | loopalgorithms | typed | multi-plan resolve (typed); nothing in the package calls it |
| `_resolve_schedule_vars` | plan, registry | untyped only |  |
| `resolve` | la | typed | process preparation, ProcessContext(la), init(la, ...) (typed); the typed callers lose the type anyway through _registry_field |
| `_resolve_plan` | la | untyped only |  |
| `_resolve_keyed_plan` | keyed_la, registry | typed | multi-plan resolve (typed); result goes into with_keymap |

### src/LoopAlgorithms/Resolving/Scopes.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_point_routes_at_storage` | wiring, Sc | untyped only |  |
| `_point_route_at_storage` | r, Sc | untyped only |  |
| `_look_up_storage_names` | storage, names | untyped only |  |
| `_resolve_scopes` | la, Outer | untyped only |  |
| `_compute_node_scope` | la, Outer | untyped only |  |
| `_add_scoped_names` | inherited, names | generator |  |
| `_find_returns_read_in_plan` | la | untyped only |  |

### src/LoopAlgorithms/Resolving/Typed.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_compute_node_scope_typed` | LA, Outer, path | generator |  |
| `_find_returns_read_in_plan_typed` | LA | generator |  |

### src/LoopAlgorithms/Resolving/Wiring.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_resolve_wiring` | la, registry, inherited_global | untyped only |  |
| `_group_wiring_untyped` | registry, wiring | untyped only |  |
| `_merge_global_wiring_untyped` | left, right | untyped only |  |
| `_merge_wiring_untyped` | left, right | untyped only |  |
| `_get_wiring` | grouped | untyped only |  |
| `_retarget_owner_routes_untyped` | bucket | untyped only |  |
| `_read_child_namespace` | plan | untyped only |  |

### src/LoopAlgorithms/Routines/Routines.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `Routine` | args | typed | user code, parse_plan (typed); result Any |

### src/Matching.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `dynamic_equals` | a, b | dispatch only |  |
| `dynamic_match` | a, b | untyped only |  |
| `dynamic_equals` | m1, m2 | dispatch only |  |
| `dynamic_equals` | a, b | dispatch only |  |
| `dynamic_equals` | a, b | dispatch only |  |

### src/PrecompileInterface.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `precompile_interface` | p | typed | process construction (typed per plan type); MEASURED 2026-11-06 for ::InlineProcess: unblocked, +30 method instances on the workload |
| `precompile_interface` | ip | typed | process construction (typed per plan type); MEASURED 2026-11-06 for ::InlineProcess: unblocked, +30 method instances on the workload |
| `precompile_interface` | manager | typed | process construction (typed per plan type); MEASURED 2026-11-06 for ::InlineProcess: unblocked, +30 method instances on the workload |

### src/Processes/Context.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `with_plan_registry` | p, x | typed | _init_process_context, _store_run_contexts!, cleanup (typed per process type) |
| `_getcontext_nokeymap` | p | typed | typed process callers (cleanup, isinteractive, init) |

### src/Processes/InlineProcess/Constructors.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_build_inline_process` | func, inputs_overrides, context, lifetime, kwargs | typed | InlineProcess(...) and its kwcall (typed per func and keyword type, i.e. per handle set) |

### src/Processes/Process/Constructors.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `_build_process` | func, inputs_overrides, context, lifetime, kwargs | typed | Process(...) and its kwcall (typed per func and keyword type) |

### src/Processes/Process/ProcessList.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `remove_process!` | p | dispatch only |  |

### src/Registry/Builder.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `find_or_add_entry!` | E | untyped only |  |
| `find_same` | algo | untyped only |  |
| `add_again!` | algo | untyped only |  |
| `replace_algo!` | new | untyped only |  |
| `with_autokey` | algo | untyped only |  |
| `set_lookup_key!` | algo | untyped only |  |
| `delete_lookup_key!` | algo | untyped only |  |
| `add` | algo, (unnamed) | untyped only |  |
| `add!` | algo, multiplier | typed | setup_registry (Package) loops over typed state/algorithm tuples |
| `check_key_unused` | algo | untyped only |  |

### src/Registry/GeneratedValues.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `read_field` | x | untyped only |  |
| `build_tuple` | like | untyped only |  |

### src/Registry/LookupKey.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `LookupKey` | algo | typed | generated registry setup, one new handle type per Unique; result always LookupKey |
| `known_lookupkey` | T | generator |  |
| `lower_to_lookupkey` | T | untyped only |  |
| `lower_to_lookupkey` | matcher | untyped only |  |
| `lower_type` | T | typed | typed caller with a constant UniquePlanId; result always Symbol |
| `lower_value` | x | untyped only |  |

### src/Registry/Registries.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `dynamic_findkey` | reg, obj | untyped only |  |
| `dynamic_findfirst_algotype` | T, reg | untyped only |  |
| `dynamic_findfirst_matcher_type` | M, reg | untyped only |  |

### src/RoutingInterface/HookExtensions.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `rebuild_with_fields` | w | dispatch only |  |

### src/RoutingInterface/RedirectDef.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `Redirect` | namespaces | typed | same as Route |

### src/RoutingInterface/RouteDef.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `dynamic_resolve_wiring` | reg, r | untyped only |  |
| `Route` | namespaces | typed | user code, DSL, update_keys (typed; new type per held Unique); result Any |

### src/RoutingInterface/ShareDef.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `Share` | algo1, algo2 | typed | same as Route |

### src/RoutingInterface/Sharing.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `dynamic_resolve_wiring_pairs` | reg, s | untyped only |  |

### src/SubContextRefs.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `dynamic_resolve_scref` | reg, match, object | untyped only |  |
| `_dynamic_object_sckey` | reg, object | untyped only |  |

### src/Threaded/CompositeAlgorithms.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `ThreadedCompositeAlgorithm` | args | untyped only |  |

### src/Utils.jl

| function | @nospecialize arguments | callers | note |
|---|---|---|---|
| `new_instance` | T, fields | typed | typed constructors (handles, lifetimes, Var, wiring, plans); result Any anyway (ccall) |
| `findfirst_unspecialized` | f, args | untyped only |  |
