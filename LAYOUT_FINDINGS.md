# Layout findings: stray functions and interface outside the moves of `refactor/contexts-processes-pausing`

Found 2026-11-03 by three read-only sweeps of `src/` at `d6292ee`/`dc58e0d`. Each sweep read the definitions it flagged.
Spot-checked by hand: `Context/Vars.jl:53`, `Trackers/AlgoBranch.jl:15`, `Registry/Registries.jl:274/279`,
`Routines/Routines.jl:37/51`, `Functions.jl:613/625`, `Interactive/ContextExchange.jl:228`. "Unused" means no
caller found by grep in `src/`; other packages (InteractiveIsing, IsingLearning) were not checked.

**Before acting on any row: check whether another branch already moved or deleted it** (BRANCHES.md). Line numbers are
as of the commits above.

Rules the findings are measured against:
1. `Interface.jl`: an abstract type's contract (fallbacks, must-implement methods, the abstract type's own getters).
2. `Hooks.jl`: functions with a default that other types extend, no `_` prefix, header lists where they are extended.
3. A type's methods of a hook live in the file that defines the type, in a delimited "Hook extensions" section at the
   end (`HookExtensions.jl` only for a type with its own folder of several files).
4. `Accessors.jl`: a concrete type's getters and setters.
5. No forwarding aliases (a function whose whole body calls another with the same arguments).

Kinds: **(a)** hook or fallback in a machinery file, **(b)** extended hook with a `_` prefix, **(c)** method far from
its type, **(d)** getters in machinery, **(e)** forwarding alias, **(f)** duplicate, dead file, or file content not
matching its name.

## Context/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `Context/SubContext.jl:13` | `newdata(sc, data)` only calls `withdata` | e | delete, use `withdata` |
| `Context/ProcessContexts.jl:208` | `Base.replace(pc, args)` only calls `_replace_subcontexts` | e | one function |
| `Context/RuntimeContext.jl:66` | `merge_runtime_return(rc, ::Val{:_captured_returns}, args)` only calls `_merge_into_captured_returns` (no other caller) | e | inline |
| `Context/StructDefs.jl:44-55` | "SUBCONTEXT VIEW" docstring with no struct; `export inject` | f | `View/StructDef.jl`, `View/ContextView.jl` |
| `Context/DynamicRouter.jl` | not included anywhere | f | delete or include |
| `Context/Vars.jl:44`, `StoredValues/ReadingWriting.jl:38`, `View/Locations.jl:393` | `stored_value_at`: declared in machinery, methods in three files | a | an Interface/Hooks file in `StoredValues/`, methods with their types |
| `Context/Vars.jl:53` | `getindex(c::SubContext, vars::Var...)` calls `getindex(::SubContext, ::Var)`, which has no method | f | delete or add the method |
| `Context/Showing.jl:89/109` | `_subcontext_var_lines` twice, same body but `getdata` | f | one method |
| `Context/View/Locations.jl:374` | `runtime_values(::ProcessContext, ::Val)`: the `ProcessContext` method of the bundle hook | c | `Context/RuntimeContext.jl` |
| `Context/View/Locations.jl:193`, `:139` | `getregistry(scv)`, `view_instance_type` | d | `ContextView.jl` properties |
| `Context/View/Locations.jl:405` | `create_merge_tuples_expr`, marked unused | f | delete |
| `Context/View/ContextView.jl:34` | `algo_to_subcontext_name`: docstring describes something else | f | fix docstring |
| `Context/View/ContextView.jl:44` vs `RoutingInterface/Construction.jl:28` | `wiring_from_tuple_type` / `wiring_from_type` (unused) | f | keep one |
| `Context/Carried/Writes.jl:30` (+ `AlgorithmWrites.jl`, `PlanWrites.jl`, `Interactive/ContextExchange.jl:259`) | `_find_writable_fields`: `::Any` default extended per node type | a, b | `Context/Carried/Hooks.jl`, no `_` |
| `Context/Carried/RuntimeContextTypes.jl:49` | `_view_node(::Type{<:PlanWiringView})` | c | with the other `PlanWiringView` getters |
| `Context/View/Old/ProcessContextView.jl:33` | keyword `inject` shadows the function `inject` (bug) | — | — |

## Registry/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `Registry/Interfaces.jl:33,131-132` | hooks `registry_entrytype`, `registry_allowmerge` mixed with rule machinery (`ask_type_rule`, `assign_entrytype`, `same_algorithm`, `autokey`, ...) | a, f | `Registry/Hooks.jl` + e.g. `Registry/Rules.jl` |
| `Registry/Findability.jl:8-10` | `isstaticallyfindable(::Any)`, extended in `ContextExchange.jl:123` | a | `Registry/Hooks.jl` |
| `Registry/LookupKey.jl:28-32` | `lower_matcher`, documented as a hook | a | `Registry/Hooks.jl` |
| `Registry/Updating.jl:6,10` | `update_keys`, extended in RoutingInterface and LoopAlgorithms | a, e | `Registry/Hooks.jl` |
| `Registry/Registries.jl:274/279` | `all_algos` / `all_named_algos`: same body | f | keep one |
| `Registry/SimpleRegistry.jl:15` | `all_algos(r) = getalgos(r)` | e | — |
| `Registry/Keys.jl:35` vs `Registries.jl:217` | two key lookups doing the same; key functions split over two files | f | all in `Keys.jl` |
| `Registry/Registries.jl:16-19` | `RegistryLocation` struct + getters in machinery | d | struct-def / accessors file |
| `Registry/TypeEntries/Methods.jl:100` | `_unwrap_algotype` re-implements `algotype` | f | use `algotype` |
| `AbstractTypeDefs.jl:257-271` | `AbstractRegistry` error stubs | a | `Registry/Interface.jl` (new) |

## RoutingInterface/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `RoutingInterface/Resolving.jl:5` | `resolve(reg, wiring...) = resolve_options(...)` | e | rename `resolve_options` to `resolve` |
| `RoutingInterface/Backend.jl:6-44` | getters of `Wiring`, `ReturnDemand`, `PlanWiringView` in a resolution file; `child_wiring` is in `LoopAlgorithms/Accessors.jl:34` | c, d | one accessors file for wiring types |
| `RoutingInterface/Backend.jl:47/108` | `_tuple_field_types` / `_wiring_tuple_types`: same body | f | keep one |
| `RoutingInterface/Backend.jl:153`, `RouteDef.jl:110` | `_route_target_lookup_error`, `_route_endpoint_label`: unused | f | delete |
| `RoutingInterface/Construction.jl:33,42` | `Wiring`/`PlanWiring` constructors far from their structs (`AbstractTypeDefs.jl`) | c | next to the structs |
| `RoutingInterface/Sharing.jl:27` | `contextname(::Any) = nothing` | a | Interface/Hooks file |
| `RoutingInterface/Routes.jl`, `Sharing.jl:6-25`, `RedirectDef.jl:64-83` | getters of `Route`, `Share`, `Redirect` spread out | d | `Accessors.jl` |
| `RoutingInterface/Apply.jl` | empty body, not included | f | delete |

## InputInterface/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `InputInterface/StructDefs.jl:5,15` | `target_type(::InputInterface)`, `function get_target end`: the contract in the struct file | a | `InputInterface/Interface.jl` |
| `InputInterface/StructDefs.jl:5,71`, `Interactive.jl:21` | `target_type`: unused, same as `get_target` | f | delete |
| `InputInterface/StructDefs.jl:86-89` | "Backend" docstring with nothing after it | f | delete |
| `InputInterface/Resolving.jl:19` | `get_target_name(ov) = get_target(ov)` | e | use `get_target` |
| `InputInterface/Resolving.jl:16-17` | `get_ref`, `get_vars` getters in machinery | d | `Interface.jl` / `Accessors.jl` |
| `InputInterface/Resolving.jl:68` | `resolve(::Any) = ()`: catch-all of `resolve` | a | the file owning `resolve` |
| `InputInterface/Resolving.jl:100` | `Base.merge(context, ovs...)` only calls `merge_resolved_inputs` | e | one function |
| `InputInterface/Interactive.jl:80,100,103` vs `LoopAlgorithms/DirectRuns.jl:27,47` | lifecycle-spec merging split over two folders | c | one place |

## Identifiable/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `Identifiable/AbstractInterface.jl` | the contract file, not named `Interface.jl` | f | rename |
| `Identifiable/IdentifiableAlgos.jl:13-31` | `algoname`, `varaliases`, `algotype`, `getkey(::Type)`, `mergereturn` repeat the abstract methods with the same body | f | delete copies |
| `Identifiable/Matching.jl:5-8` | `id` (repeats `AbstractInterface.jl:22`), `setid` | d, f | `id`: delete; `setid`: setters |
| `Identifiable/IdentifiableAlgos.jl:17` | `getvaraliases`: second name for `varaliases` | f | keep one |
| `Identifiable/VarAlias.jl:52,59` | `getvaraliases(::Any)`, `setvaraliases` fallbacks (a second fallback at `AbstractInterface.jl:81`) | a, f | `Interface.jl`, one fallback |
| `Identifiable/Identifiable.jl:13` | `autokey_basename` default, extended in `GeneralState.jl:37` | a | a Hooks.jl |
| `Identifiable/Identifiable.jl:4,15` | `nameoftype`, `isidentifiable` (unused) in the include file | f | — |
| `Identifiable/AbstractInterface.jl:19,21` | `staticmach_by` (misspelt), `contextkey`: unused | f | delete |
| `Identifiable/Keys.jl`, `TypeIdentity.jl` | not included; `Keys.jl:12` does not parse | f | delete |

## ProcessEntities/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `ProcessEntities/ProcessEntities.jl:3-6` | `init`/`step!`/`cleanup` fallbacks, `function _step! end` in the include file | a | `ProcessEntities/Interface.jl` |
| `ProcessEntities/ProcessEntities.jl:6` | `_step!`: extended by every plan/step type | b | no `_`, header listing extensions |
| `ProcessEntities/StepReturns.jl:55-56` | `updated_names`: a hook users and `@StepAlgorithm` extend | a | `ProcessEntities/Hooks.jl` |
| `ProcessEntities/AlgoStates/Destructure.jl:27` | `getdestructure_id(x) = getdynamicstore_id(x)` | e | — |
| `ProcessEntities/AlgoStates/DynamicStore.jl:72-78`, `Destructure.jl:62-67` | `thincontainer`, `_contained_type`, `_unwrap_container`: per-type, no default; `Destructure.jl:66` calls undefined `contained_type` | b, f | Hooks.jl or delete |
| `ProcessEntities/AlgoStates/GeneralState.jl:148/158` | two functions with the same body | f | keep one |

## LoopAlgorithms/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `LoopAlgorithms/Utils.jl:8` | `getregistry(::Any) = error(...)`: package-wide fallback | a | an Interface file |
| `LoopAlgorithms/Utils.jl:17,40` | `update_keys` methods for `LoopSpec`, `LocalPlanOption` | c | with their types |
| `LoopAlgorithms/Utils.jl:10` | `_attach_registry(::LoopSpec)` fallback; other methods in `Accessors.jl:103`, `FinalizedAlgorithm.jl` | a, b | `Interface.jl`, no `_` |
| `LoopAlgorithms/Traits.jl:21-35` | `iscomposite`, `steps_inline` defaults extended in Threaded and FinalizedAlgorithm | a | `Hooks.jl`; type methods with their types |
| `LoopAlgorithms/LoopCursor.jl:16` | `loop_cursor(::Any, ::Val)` default extended per plan type | a | `Hooks.jl` |
| `LoopAlgorithms/Setup.jl:37-38` | `parse_parser_option(::ParserOption)`: abstract contract in parsing machinery | a | `Interface.jl` |
| `LoopAlgorithms/PlanOptions.jl:101-102` | `setstates`/`setoptions(::AbstractPlan)` fallbacks | a | `Interface.jl` |
| `LoopAlgorithms/Accessors.jl:83,97-100,113` | `LoopSpec` fallbacks (`setoptions`, `getstoredinits`, `getstoredoverrides`, `getpersistentcontext`, `context`, `isresolved`) | a | `Interface.jl` |
| `LoopAlgorithms/Flatten.jl:66` | `states(::LoopSpec) = error(...)` | a | `Interface.jl` |
| `LoopAlgorithms/Redirect/Materialization.jl:6` | `getstoredredirects` getter | d | `Accessors.jl` |
| `LoopAlgorithms/Interface.jl:94` | `replace_fields`: generic machinery in the contract file | f | `Utils.jl` / `GeneratedCode/` |
| `LoopAlgorithms/Step.jl:105` | `_plan_step_exprs`: every `steps_inline` plan type must add one | b | `Hooks.jl`, no `_` |
| `LoopAlgorithms/PlanOptions.jl:54,105`, `Keys.jl:14-92`, `Accessors.jl:91,103` | `_collect_root_options`, `_collect_tree_wiring`, `_entity_key`, `_nested_loop`, `_namespace_tuple`, `_key_source`, `_with_lifecycle`, `_attach_registry`: extended by other types | b | no `_` |
| `LoopAlgorithms/CompositeAlgorithms.jl:97,128` | `inc!`/`inc` on `CompositeLoopCursor` | c | `LoopCursor.jl` |
| `LoopAlgorithms/Init.jl:1,5` | `init(::ProcessAlgorithm, ::InitContext)`, `cleanup(::ProcessAlgorithm, ::LoopContext)` | c | with the ProcessEntities defaults or `src/Init.jl` |
| `LoopAlgorithms/Edit/Constructor.jl:15-155` | per-plan-type methods (`_constructor_type`, `_default_schedule_entry`, ...) incl. Threaded ones | a, c | with each type or `Hooks.jl` |
| `LoopAlgorithms/Showing.jl:50,145,169`, `Step.jl:459` | `Routine` show and step outside `Routines/` | c | `Routines/` (borderline) |
| `LoopAlgorithms/Accessors.jl:31-37` | `global_wiring`, `child_wiring`, `isempty(::PlanWiring)` | d | with `PlanWiring`'s other getters |
| `LoopAlgorithms/Accessors.jl:24-28,1-2` | `LoopAlgorithm` constructors; re-exports | f | constructor file |
| `LoopAlgorithms/Accessors.jl:129-151` | Base protocol on `LoopSpec` (`getindex`, `getproperty`, `length`, ...) | f | `BaseExt.jl` |
| `LoopAlgorithms/Interface.jl:32` | `getschedule(::LoopAlgorithm)`: concrete getter in the contract | d | `Accessors.jl` |
| `LoopAlgorithms/Interface.jl:29`, `Accessors.jl:57` | `subalgorithms`: unused aliases | e | delete |
| `LoopAlgorithms/Accessors.jl:49,100,116,134`, `CompositeAlgorithms.jl:78,81,110`, `ParameterReplacement.jl:34-45`, `Edit/Constructor.jl:10` | `context(la)`, `id`, `getindex(cla, ::Symbol)`, `get_intervals`, `type_instances`, `setrepeats`/`setintervals`, `_stored_schedule_spec` | e | — |
| `LoopAlgorithms/Recipes.jl:9,17`, `CompositeAlgorithms.jl:24`, `Routines.jl:19` | two sets of type aliases for the same types | e | — |
| `LoopAlgorithms/Routines/Routines.jl:37/51` | `statetypes(::Routine)` twice; the second returns `()` | f | keep one |
| `LoopAlgorithms/CompositeAlgorithms.jl:30`, `Routines.jl:26` | `newfuncs` repeats `rebuild_loopalgorithm_funcs` | f | keep one |
| `LoopAlgorithms/CompositeAlgorithms.jl:64`, `Routines.jl:67` | `intervals`, `lifetimes`: second getters of the schedule field | f | keep `getschedule` |
| `LoopAlgorithms/Edit/Constructor.jl:144,155` | `changeintervals`/`changeinterval` duplicate `setintervals`/`setinterval`; file name does not match (edit tools); `Edit/` included from the top file | f | rename, keep one |
| `LoopAlgorithms/Accessors.jl:134,138`, `BaseExt.jl:4`, `Keys.jl:163` | `getindex` on `LoopSpec` in three files | f | one place |
| `LoopAlgorithms/Flatten.jl` vs `Fusing/Fusing.jl` | flattening split; neither file matches its name | f | — |
| `LoopAlgorithms/Fusing/Fusing.jl:1,105` | `isfused` exported and called, not defined; `Fusing/ContextExt.jl` all commented out but included | f | — |
| `LoopAlgorithms/Traits.jl:1-7` | `algo_and_interval_iterator`, `LoopAlgorithmTypes`: not traits | f | — |
| `LoopAlgorithms/KeyReplacement.jl` | empty stub, not included | f | delete |
| `LoopAlgorithms/Init.jl:10-58`, `DirectRuns.jl:94`, `src/Init.jl` | init on a plan in three files; `Init.jl:42` "for testing" | f | — |
| `LoopAlgorithms/Setup.jl:189` | `LoopAlgorithm(PlanType::Type, ...)` returns a plan, not a `LoopAlgorithm` | f | rename (`build_plan`) |
| `LoopAlgorithms/Utils.jl:1,43`, `CompositeAlgorithms.jl:69-124`, `GetFirst.jl`, `Setup.jl:214`, `Fusing.jl:63` | unused: `replace_name!`, `recursive_update_cla_names`, `get_this_interval`, `hasflag`, `track_algo`, `num_funcs`, `get_funcs`, `tupletype_to_tuple`, `getvals`, `unwrap_cla`, `getfirst_node`, `_build_plan_typed`, `flatten_comp_funcs_typed` | f | delete after checking |

## CompositeDSL/, Legacy/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `CompositeDSL/StateAndRoutes.jl:174-192,227,333` | `DSLRules`/`CurrentDSL` and their `::DSLRules` fallbacks, extended by `Legacy/Legacy.jl:16,23` | a, b | `CompositeDSL/Interface.jl`, no `_` |
| `CompositeDSL/Resolution.jl:8-9` | `_dsl_step_positional_names`, overridden by `@StepAlgorithm` output | b | a Hooks.jl, no `_` |
| `CompositeDSL/Resolution.jl:12-13` | `_dsl_with_customname` returns `algo` in both methods (6 call sites) | e | delete |
| `CompositeDSL/Locals.jl:171`, `GeneratedCode/Context/SubContextView.jl:6` | `_is_scoped_runtime_partition` / `_writable_runtime`: same Union, two names | c, f | `Context/ContextPartitions.jl` |
| `CompositeDSL/StateAndRoutes.jl:868-963` | output/returns, `@alias`, `include_if`, `finally` parsing | f | `Statements.jl` / `References.jl` |
| `Legacy/` | `GeneratedLoops.jl`, `GeneratedStep.jl` are dead generated-loop code, not legacy DSL; legacy branches also live in `StepAlgorithmMacro.jl:390-422`, `CompositeDSL/Macros.jl` | f | — |

## Threaded/ (layout only; fixed later as DaggerPlan)

| Where | What | Kind |
|:--|:--|:--|
| `Threaded/CompositeAlgorithms.jl:32/43` | `statetypes` twice | f |
| `Threaded/CompositeAlgorithms.jl:61` vs `:37` | `id` duplicates `getid` | e |
| `Threaded/CompositeAlgorithms.jl:79-86` | `plan_child_namespace` copy of `LoopAlgorithms/Accessors.jl:67-74` | f |
| `Threaded/CompositeAlgorithms.jl:66,76` | cursor `inc!`/`inc` | c |
| `Threaded/CompositeAlgorithms.jl:74` | `getvals` unused | f |

## Packaging/, GeneratedCode/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `Packaging/Accessors.jl:26,35` | `getmultiplier(::SubContextView, ::AbstractIdentifiableAlgo)`: generic, overrides `Tools.jl:65` | a, c | `Context/View/` |
| `Packaging/Accessors.jl:12-24`, `Constructor.jl:102`, `SubPackage.jl:30-38` | hook methods (`registry_entrytype`, `algoname`, `haskey`, `hasautokey`, `Autokey`, `getkey`, `match_by`, ...) in accessors | a | delimited hook section / `Packaging/HookExtensions.jl` |
| `Packaging/Constructor.jl:18` | `package(args...) = Package(args...)` | e | — |
| `Packaging/Utils.jl:19` | `routes_to_varaliases` unused | f | — |
| `GeneratedCode/Context/SubContextView.jl:10-153` | the real `merge`/`replace` of `SubContextView`, far from the type | c | `Context/View/` |
| `GeneratedCode/Registry/*.jl` | registry lookup methods split from `src/Registry/` without a header saying why | c | — |
| `GeneratedCode/Registry/Setup.jl:19` | generated wrapper apart from its generator (`LoopAlgorithms/Resolving/Registering.jl:37`) | f | together |

## Top-level files, Manager/, Interactive/, Widgets/, Trackers/

| Where | What | Kind | Suggested place |
|:--|:--|:--|:--|
| `Trackers/AlgoBranch.jl:15-16` | `repeats(::Any) = 1`, `repeats(::Any, idx) = 1`: global fallback of `repeats` | a | delete, or `Lifetimes/Hooks.jl` if meant |
| `Trackers/TreeStructure.jl:1-137` | `::Any` fallbacks (`is_decomposable`, `nbranches`, `multiplier`, ...) and plan methods; `multiplier` collides with `LoopAlgorithms/Interface.jl:36` | a, c | LoopAlgorithms Hooks/Interface |
| `Trackers/TreeStructure.jl:100` | `Base.Flatten(::ProcessAlgorithm)`: piracy on `Base.Iterators.Flatten` | f | rename |
| `Init.jl:9`, `ProcessEntities/ProcessEntities.jl:3` | two defaults of `init` | a, f | one, in a Hooks.jl |
| `Matching.jl:8,12` | `match_by` erroring default, extended everywhere | a | a Matching Hooks.jl |
| `SubContextRefs.jl:47` | `fixed_namespace(_) = nothing`, extended in LoopAlgorithms | a | a Hooks.jl |
| `AbstractTypeDefs.jl:234` | `Base.iterate(::LoopSpec)` in the type-defs file | c | `LoopAlgorithms/` |
| `AbstractTypeDefs.jl:28-29,141,202-207,232` | getters of wiring and scope types | d | accessors |
| `Manager/ProcessManager.jl:1057-1268` | recipe callbacks with defaults (`makeworker`, `copyworker`, `initstate`, ...) | a | `Manager/Hooks.jl` |
| `Manager/ProcessManager.jl:1306-1773`, `Threaded.jl:15`, extended in `ChunkedInline.jl`, `OnDemandWorkers.jl`, `ChannelWorkers.jl` | worker protocol `_worker_isdone`, `_finalize_worker!`, `_close_worker!`, `_start_slot!`, ... | b | no `_`, `Manager/Hooks.jl` |
| `Manager/ProcessManager.jl:1580,1618,1142,1159,1220,1254` | `_flush!`, `_apply_flush_policy!`, compatibility callbacks `prepare!`, `runarguments`, `consume!`, `flush!` | e | — |
| `Interactive/ContextExchange.jl:24,228` | `isinteractive` defined without `Base.`: shadows `Base.isinteractive` in the package | f | — |
| `Interactive/ContextExchange.jl:372` | `Base.view(context, varname; exchange) = ContextExchangeVar(...)` | e | — |
| `Interactive/ChannelInteractive.jl` | not included; its `Interactive{T}` clashes with InputInterface's | f | delete |
| `Interactive/Interactive.jl:1` | exports `Interactive`, `InteractiveVar` (defined elsewhere) and repeats ContextExchange's exports | f | — |
| `Saving.jl:25` | `contextdata(::ProcessContext)` | d | `Context/` |
| `Tools.jl:5-13,65,20,70-95` | `sizing_*` and `getmultiplier` for views; `processsizehint!`, `num_calls` (init-time context helpers); `getmultiplier(::AbstractContext, ::ProcessAlgorithm)` may be ambiguous against `ContextAnalyzer.jl:86` | c | `Context/View/`, `ContextAnalyzer/` |
| `Tools.jl:78` | `num_calls(..., ::SubPackage)` same body as `:70` | f | delete |
| `Tools.jl:107,112` | `loopidx(args::NamedTuple)`, `algo_call_number`: legacy | f | delete |
| `Tools.jl` | `TimeTracker` → Utils; `@hasarg` (writes a global) → CompositeDSL; exports undefined `recommendsize`, `newallocator` | f | — |
| `Utils.jl:19` vs `Unroll.jl:379` | `filter_by_type` / `typefilter`: same thing | f | keep one |
| `Unroll.jl:399` | `inner_typefilter = _inner_typefilter` | e | — |
| `Functions.jl:613/625` | `deletekey` twice; the `Pairs` method shadows the Union one's branch | f | keep one |
| `Functions.jl` | grab-bag: accessor macros (157-286) → Utils; `idx2coords` & co (576-583) are InteractiveIsing code; dead `@tryLockPause`, `@ForwardDeclare`, `getstruct`, `find_struct_in`; commented `IndentIO` copy; tuple helpers overlap `Utils.jl` | f | — |
| `Debugging.jl` | dead (undefined `getcontextð`, `getlifetime`, `preparedata!`); `@DebugMode` lives in `Functions.jl:14-143` | f | — |
| `TriggerList.jl` | marked unused; its `inc!(::CompositeTriggers)` adds to the session `inc!` | f | delete |
| `TotalInc.jl` | `total_incs` plan methods; `leafs` undefined | c, f | `LoopAlgorithms/` |
| `Widgets/Apply.jl`, `Utils/MTuple.jl` | empty | f | delete |
| `Widgets/IsBitsStorage.jl`, `ContextWrite.jl:38-46`, `RunFuncs.jl:19`, `Logger.jl:14` | not widget code (`context_broadcast!`, `unroll_apply`, `pushderef!`) | f | Utils / Unroll |
| `Trackers/PrepareHelpers.jl`, `Arena.jl` | commented out of the build | f | — |
| `Init.jl` (export line) | exports undefined `preparedata!` | f | — |
