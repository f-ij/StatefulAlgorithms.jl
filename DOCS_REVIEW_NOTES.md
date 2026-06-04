# Documentation Review Notes

These notes were written after reading the documentation pages only, before
checking implementation code. Internals were reviewed with a looser standard
than user-facing pages.

## Cross-cutting readability issues

- Several user pages rely on important words before they are explained:
  `process`, `algorithm`, `state`, `context`, `subcontext`, `view`, `registry`,
  `route`, `share`, `input`, `override`, `lifetime`, and `selector`.
- The docs explain many precise behaviors, but they do not first give a plain
  mental model of what data lives where and when user code runs.
- Many examples use placeholder types such as `Walker`, `Fib`, `Noise`, and
  `MyAlgo` without enough surrounding definition to be copyable.
- Some pages mention advanced internals from user docs, such as "registry key",
  "mapped targets", "generated view lookups", and "type stability", before a
  user can understand the practical behavior.
- The README is too short to stand alone. It does not describe what the package
  is for, the main exported ideas, or where to begin.
- The split page order is not obvious. A reader probably needs a "first process"
  path before pages about identity, routes, and analysis.

## Page notes

### `README.md`

- Not understandable on its own. "fast threaded loops" undersells the package
  and does not explain process algorithms, state, contexts, or docs location.

### `docs/src/index.md`

- Better than README, but still starts with "type-stable" and type names before
  explaining the package in plain English.
- Needs a short concept glossary or first-use explanations before the page list.

### `docs/src/man/usage.md`

- Compatibility page is fine, but it repeats the index links without a first
  reader path.

### `docs/src/user/algorithms_states.md`

- This is the main page and mostly coherent, but assumes readers already know
  what a process loop and subcontext are.
- "Registry order", "natural finite completion", "managed state",
  "runtime-only", and "where signatures" are too compressed for a beginner.
- Macro DSL section is dense and uses `@managed`, `@inputs`, and `@config`
  before fully explaining the data flow.
- Need verify examples and scheduling helpers against source.

### `docs/src/user/referencing_algorithms.md`

- Useful and clear. It depends on `Unique` and "composition", which should be
  explained nearby.
- Need verify whether fresh instance targeting truly never works, or whether it
  sometimes works through value/type matching and is merely risky.

### `docs/src/user/contexts.md`

- Needs a plain explanation of `ProcessContext`, `SubContext`, and
  `SubContextView` before using those names.
- "Existing names update mapped targets" is not plain enough. Need explain that
  returning a routed name may update another algorithm's stored value.
- "Type changes are rejected" needs an example.
- Need verify indexing forms, `initcontext` forms, and globals.

### `docs/src/user/init_analysis.md`

- Understandable for advanced users, but not self-contained because it names
  analyzer views, flattened leaves, seeded state, and view keys with little
  plain-language setup.
- This feature is opt-in by including a file under `src`; verify this is still
  accurate.

### `docs/src/user/routes_shares.md`

- Mostly understandable, but "subcontext" and "view locations" concepts need
  simple explanations or links.
- The difference between `Route` and `Share` is clear, but the examples are not
  fully copyable.
- Need verify transform-route writeback behavior and route instance limitation.

### `docs/src/user/inputs_overrides.md`

- Short and clear but too terse. It should explain target selection and whether
  values can be passed to multiple targets.
- Need verify constructor forms and order.

### `docs/src/user/vars.md`

- Clear as a reference, but relies on previous understanding of globals and
  subcontexts.
- Need verify exact `Var` forms and whether selectors can carry multiple vars.

### `docs/src/user/lifetime.md`

- Mostly clear. Need verify default lifetimes, exported status, and whether
  `repeats` is still accepted as a constructor alias.
- The phrase "shouldrun path" is internal jargon and should be simplified.

### `docs/src/user/running.md`

- Practical and clear, but `Process`, `InlineProcess`, `run`, `close`, and
  `fetch` semantics need verification. In particular, `close` behavior can be
  subtle if it updates stored context from the task result.

### `docs/src/user/copying_and_management.md`

- Dense and less self-contained than other user pages. `TaskData`, worker
  recipe, slot, flush policy, and context rebuilding need plain definitions.
- Need verify all names in the example, especially `slots(manager)`.

### `docs/src/user/value_semantics.md`

- Important but jargon-heavy. `isbits`, `match_by`, static path, type-level
  matching, and `IdentifiableAlgo` are not plain English.
- This page probably needs a user-first version and can move deeper details to
  internals.
- Need verify lookup and identity behavior against the registry code.

### `docs/src/user/interactive.md`

- Detailed, but starts with "buffered interactive updates" and type stability
  before a plain mental model.
- "Ref-like", "resolved target", "context merge machinery", and "concrete
  target variable" need simpler wording.
- Need verify the injector key, `isinteractive`, `interact!`, process overload,
  and `view(context, Var(...))` forms.

### Internals pages

- The internals pages are acceptable for readers already familiar with the
  package, but they still use dense implementation terms.
- `docs/src/internals/contexts.md` says read precedence is shared vars, routed
  vars, local vars, injected vars, but then says local and injected override
  earlier names later. Need verify and clarify read versus merge behavior.
- `docs/src/internals/process_pipeline.md` and
  `docs/src/internals/registry.md` likely need source verification because they
  describe exact file paths and order guarantees.
- `docs/src/internals/routes_shares.md` is clear for internals, but should be
  checked against route/share resolution code.

### `PERFORMANCE_OPTIMIZATIONS.md`

- This is not user documentation. It is a developer note and can keep more
  jargon, but it should define abbreviations like SROA before use.
- It refers to benchmark files and package dependency state that may be stale.
  Verify before editing or leave as a technical roadmap.

## Improvement targets after source verification

1. Add a plain-language introduction and glossary to the docs index.
2. Expand README enough that it stands alone.
3. Make the main user pages explain `context`, `subcontext`, `view`, `Route`,
   `Share`, `Input`, `Override`, `Var`, and `Unique` in plain terms before
   using them heavily.
4. Replace or explain internal jargon in user pages.
5. Verify examples and API claims against source before changing behavior
   descriptions.

## Source-verified fixes applied

- `Process(...; lifetime = 1000)` was stale. Source accepts integer counts
  through `repeats = 1000`, or explicit lifetime objects such as
  `lifetime = Repeat(1000)`.
- Lifetime types are exported, so docs no longer say to always use the
  `StatefulAlgorithms.` prefix.
- Registry identity docs now match source: direct immutable instances can match
  by value, mutable instances match by object identity, and types match by type.
- Context view read precedence in internals now matches source merge order:
  injected names override local names, local names override routed names, and
  routed names override shared names.
- Documenter rejected links from docs to `../../../test/...`; those are now
  plain path references.
