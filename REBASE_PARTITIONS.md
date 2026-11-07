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
| "Matchers compared as values" | `matches_type` and all its methods deleted (Matching.jl, UniquePlanId/HookExtensions.jl), with the value-vs-type `matcher_equals` methods (`UniquePlanId` vs `Type`, `Type{<:MatchAnyOf}`, `Type{ValMatcher{V}}`), `match_by(::Type{<:AbstractMatcher})`, `matcher_parts(::Type{MatchAnyOf})`, `dynamic_findfirst_matcher_type`. New: `endpoint_matcher(match, object)` (the matcher value of a stored SCRef), `findfirst_by_matcher` (`get_by_matcher` now calls it), `dynamic_findfirst_matcher`. `matcher_sckey(reg, m, role)` takes the matcher value; `child_matches_scref(child, m)` takes the child and the matcher value; `Var`s resolve with their matcher as the object (`_var_subcontext(c, var)`, `resolve_var_key`). The registry's walk on types (`add!`, Builder.jl) sends a plan with a merged state (`MatchAnyOf`) to the walk on values: it compared the merged id's type with its parts' types. Test: LifetimeTest "A Var is found by its matcher's value". | Partitions' `ca2f3bc5` (Vars by value through `object_namespace_key`) is replaced by this: drop it, keep its LifetimeTest testset (same name, `resolve_var`). Apply the same edits under partitions' names: `matcher_namespace_key(reg, m, role)`, `child_matches_nsref(child, m)`, `endpoint_matcher` with `partref_match`, `resolve_var` / `c[var]` passing `location_storage(var)`; delete the same functions. Partitions' TODO item "Matchers are compared as values" is then done except what this row's report leaves open. |
