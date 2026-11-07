# Rebasing `refactor/partitions` onto `refactor/plan-compiles`: the log

`refactor/partitions` was rebuilt on `refactor/plan-compiles` at `b3da057a` (2026-11-06). Every commit on
plan-compiles after `b3da057a` has a row here: what it changed, and what partitions has to do when it is rebased onto
plan-compiles. Partitions renamed the reference code (`SubContextRefs.jl`: SCRef → nsref/partref, `resolve_scref` →
`resolve_nsref`, `matcher_sckey` → `matcher_namespace_key`, `child_matches_scref` → `child_matches_nsref`), and a
`Var` there is an unresolved `VarLocation` (`resolve_var`, not `resolve_var_key`), so rows that touch those files name
both spellings.

Keep this up to date: every commit on plan-compiles adds its row here, until partitions is rebased.

| Commit | What changed on plan-compiles | What partitions has to do |
|---|---|---|
| `d2d9ee0b` | `Base.@nospecializeinfer` dropped where no argument is `@nospecialize` | Take it; drop the same annotations in code partitions added or moved. |
| `7be74085` | Registry type walk: `find_same` no longer throws `NeedsValues` for a dynamic id; `resolve` numbers every id before step 1 (documented in `generate_registry_setup`, test "no dynamic ids reach the registry build") | Take it: partitions still has the check at `src/Registry/Builder.jl:135`. |
| `f99e4be6` | NOSPECIALIZEINFER_INDEX.md and a TODO item | Take it; add partitions' own `@nospecializeinfer` blocks to the index. |
| `6850df9d` | `Autokey`: `@nospecialize` on the algorithm and id; key from `autokey(T, i)` instead of the generated `static_symbol` | Take it; check partitions' callers of `static_symbol`. |
| `8b53c968` | TODO item (`IdentifiableAlgo` and `@nospecializeinfer`) | Take it. |
| `bd09f61d` | Unique ids replaced through `map_matchers_of_type`; ReplaceIds.jl, the mode structs and `rebuild_with_fields` removed | Partitions' `rebuild_with_fields` for `Route`/`Share`/`Redirect` (RoutingInterface/HookExtensions.jl) and the `VarLocation` holders get `map_matchers_of_type` methods instead. |
| `b0e9d2cc` | TODO item (blocking inference per function) | Take it. |
| "No Base.== on matchers" | `UniquePlanId`'s `Base.:(==)` and `Base.hash` removed: two ids compare with `matcher_equals(::UniquePlanId, ::UniquePlanId)` (and `dynamic_equals`), both in UniquePlanId/HookExtensions.jl, through `same_unique_id` (StructDef.jl). `==` on two ids is Base's (`===`). The unloaded `src/Identifiable/Keys.jl` (`AbstractKey == Symbol`) deleted. | Same edits in StructDef.jl / HookExtensions.jl; delete `src/Identifiable/Keys.jl`; tests comparing ids with `==` use `matcher_equals`. |
