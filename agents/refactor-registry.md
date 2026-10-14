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

## Plan: simplify and modularize the registry (owner, 2026-10-14)
Readable, semantically named, close to the old `add`-based construction; interfaces wherever possible; speed first.
1. Rules as an interface (src/Registry/Interfaces.jl): entry type, what counts as the same algorithm, automatic name,
   merging, states first. Defined on types; the build code only calls these.
2. `RegistryBuilder` with `add!(builder, algo, multiplier) -> keyed algo` (the old `add`), `registry(builder)`;
   the plan walk as `add_tree!` / `add_states!` / `add_children!`; the "known only by its type" value and its helpers
   named for what they are and read.
3. Files: builder, plan walk, code generation separate; the generated function in src/GeneratedCode/.
4. Redefining a rule regenerates the layout (the generated function returns its code with the methods it depends on).
5. Tests: the generated path is taken for the usual plan shapes; redefining a rule updates the registry.
