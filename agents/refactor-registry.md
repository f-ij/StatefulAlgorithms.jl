# refactor/registry: notes, baseline and plan

Branch `refactor/registry` sits on `refactor/no-first-step` (2026-10-14). Three commits: compile-time fixes (code that
runs while preparing a plan or generating code compiled once), the registry collected as plain values in one walk,
and registry setup as a generated function (layout from types while compiling, values read from the plan).

## Performance baseline (keep or beat; regressions only for an abstraction the owner agrees to)
Measured on this branch at a4c581f, machine otherwise quiet. Raw files next to this one.
- Registry step (scratchpad reg_all2.jl; first call = compile + run, CPU): "3-level Routine" 9 ms first call,
  0.2 µs warm, creating an InlineProcess 15.8-16.0 µs warm; "wide composite, 32 children" 40-42 ms, 1.9-2.0 µs,
  46.5-47.7 µs (registry-baseline-registry.txt).
- Compile (perf/compile.jl, CPU s, min of 3; registry-baseline-compile.txt): first InlineProcess run 0.16-0.41 s
  for the small cases, 1.85 s wide; first Process run 0.07-0.21 s; rebuild 0.07-0.29 s; precompile 11.4 s (wall).
- Loop time (perf/run.jl --runtime-only; registry-baseline-runtime.txt): every row as on refactor/no-first-step.

## How the registry code is organized (after the simplification, 2026-10-15)
- Registry/Interfaces.jl: the rules that decide a registry's layout (entry type, states first, what makes two
  algorithms the same, automatic keys `Lin_1`, merging), defined on types. Internal: only the package's own types
  extend them.
- Registry/Builder.jl: `RegistryBuilder`; `add!(builder, algo, multiplier) -> keyed algo` (the old `add`, which is
  now a thin wrapper), `registry(builder)` (on values), `write_registry_expr(builder)` (the code that builds it, for the
  typed path).
- Registry/KnownByType.jl: a value known only by its type while a layout is worked out from types, with
  `read_field`, `build_tuple`, ... that read it the same way as a value. A value the type alone decides is a constant
  in the generated code (`is_known_value`: singleton types, tuples of known values); `build_from_parts` writes the
  code that makes a struct, with `Expr(:new, T, fields...)` for the package's own types (no constructor to infer and
  inline; no separate compile when fields are constants) and a constructor call for another package's plan type.
- LoopAlgorithms/Resolving/Registering.jl: the walk over a plan: `register_tree!`, `register_states!`, `register_children!`,
  `register_child!`; `build_registry_from_values` (run time) and `generate_registry_setup` (from types).
- GeneratedCode/RegistrySetup.jl: the generated `build_registry_and_key_plan`: its generator returns the code the type
  walk writes (`generate_registry_setup`). Each registry entry's multipliers and lookup table are constants shared by
  all plans of the type (`write_registry_expr`, `write_lookup_table_expr`); a registry's are only read.
  Same design with constructor calls instead of `new` (shared objects behind `Core.compilerbarrier(:const, x)`):
  branch `exp/registry-constructor-calls` (d1b4cfc), same warm time, 0-5 ms slower first call.
  Archived alternative without a generated function, with measurements: branch `archive/runtime-registry-setup`
  (agents/archive-runtime-registry-setup.md there).
- Registry/Registries.jl, TypeEntries/: reading a registry and its entries (finding, keys, multipliers, listing).
- Tests: test/RegistryBuildTest.jl (typed path taken, both paths agree, wide and deep plans).

## Done (from the plan)
1-5 of the plan are done (wip/registry-simplify, fast-forwarded into this branch). Not done: Packages name their
keys their own way (`Autokey(::Package)`); unifying it would change the keys of Packages inside plans.
