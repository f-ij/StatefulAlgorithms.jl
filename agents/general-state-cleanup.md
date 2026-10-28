# GeneralState.jl cleanup

Found 2026-10-28 on `refactor/plan-compiles` (f486594) by reading `src/ProcessEntities/AlgoStates/GeneralState.jl`
and grepping its callers; nothing was run or changed. Since 81c7222 the registry merges no states, so the only
caller of `merge(::GeneralState, ::GeneralState)` is `@merge` (`_composite_dsl_merge_states!`,
`src/CompositeDSL/StateAndRoutes.jl:551-558`). Much of the file is left over from the registry merge.
Related: the URGENT merge-semantics item in `TODO.md` (its point 13 keeps `merge` of two `GeneralState`s for `@merge`).

Suggested order: first verify 4-7 (compiled-method listing, entry points, a probe) and, if they hold, remove that
machinery; then 1-3 and 8-12.

## Fix

1. `_general_state_optional` (`GeneralState.jl:220-227`) has a bare `try … catch; return default`. It is meant for
   "source not initialized yet", but any error from `getproperty` on the context (a wrong route, a bug in a
   `Redirect`, a type error) silently becomes the default value. Catch only the not-initialized case, or check it
   before reading.
2. Stale "registry merge" text: `GeneralState.jl:74` ("during registry merge"), the `Base.merge` docstring
   `GeneralState.jl:175-176` ("higher-level registry/setup code … same outer key"), and the include comment
   `src/StatefulAlgorithms.jl:52`. Describe `@merge` as the caller.
3. The init error says `LoopAlgorithm @state requires input …` (`GeneralState.jl:215`); users write `@state` in a
   block, so name the block's state instead.

## Probably vestigial (not proven dead)

4. The "undocumented overlap" warning (`GeneralState.jl:133-134`) looks unreachable: `_composite_dsl_merge_states!`
   marks every field of every merged state as explicitly shared right before `merge`, so `undocumented` is always
   empty. That branch is the only user of `_general_state_overlap_suggestion`, whose suggestions (`@merge a, a`,
   `@merge f.x, n.x`) also error today (merge-semantics item, point 10).
5. If 4 holds, the type parameter `ExplicitlySharedFields` and `mark_general_state_fields_explicitly_shared` only
   exist to suppress that warning and can go.
6. `DiagnosticFieldPaths` and `prefix_general_state_diagnostic_paths` (called from
   `_composite_dsl_prefix_state_diagnostic_paths`, `StateAndRoutes.jl:527`) then only feed the "multiple defaults"
   warning. Decide whether that warning is wanted: `@merge` is always intentional, so "later defaults will override"
   may be noise. Without it, both go too.
7. No callers in `src`, `test`, `ext`, `docs`, `examples`: `general_state_explicitly_shared_fields`,
   `general_state_diagnostic_field_paths`, and the exported alias `InlineState`.

If 4-6 hold, `GeneralState` becomes `GeneralState{Fields, Required, DefaultValuesBuilder}`.

## Duplication and small cleanups

8. `_merge_general_state_fields` and `_general_state_symbol_union` are the same ordered union; the first also
   computes an unused `overlaps` (`GeneralState.jl:140`). `mark_general_state_fields_explicitly_shared` writes the
   union a third time. Keep one.
9. `_merge_general_state_required_fields`: `Required ⊆ Fields`, so the four flags reduce to "no side gives the field
   a default".
10. Untyped arguments, against the `x::T where T` rule: `context` and `state` in `_general_state_required`,
    `context` and `default` in `_general_state_optional`.
11. `_general_state_without` names its type parameters `B, Shared, Paths`; the rest of the file uses the full names.
12. The comment at `GeneralState.jl:26-27` (how a state's handle matches) floats between the struct and
    `autokey_basename`; attach it to what it describes or move it to the struct docstring.
