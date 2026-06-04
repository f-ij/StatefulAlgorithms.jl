# Runtime Inputs And Init Inputs Plan

This note captures the current API direction for separating initialization data
from per-run LoopAlgorithm inputs.

## Vocabulary

The package should expose two different concepts with different names:

- `Init(...)`: init-time values used by `ProcessAlgorithm` init methods to build
  persistent context state.
- `@input`: LoopAlgorithm-level runtime values bound before a run starts.

The existing `Input(...)` API should be renamed or aliased to `Init(...)`.
`Input(...)` can remain as compatibility surface, but new examples and docs
should use `Init(...)`.

## Conceptual Split

`ProcessAlgorithm` init inputs:

- belong to individual `ProcessAlgorithm` contexts
- are consumed during context initialization
- can create persistent state, buffers, refs, RNGs, graph handles, etc.
- should be changed through reinitialization or future `prepare(...)` APIs

LoopAlgorithm runtime inputs:

- belong to the enclosing `LoopAlgorithm`
- are declared with `@input`
- are merged before the loop starts
- are visible to routed calls like ordinary context values
- should not be merged inside the hot loop
- do not own persistence across runs

Persistent buffers and state should stay in `@state` or in `ProcessAlgorithm`
managed state. Runtime inputs may be reused across runs, but they are bindings,
not storage.

## Proposed User Flow

Construct a loop algorithm:

```julia
algo = @CompositeAlgorithm begin
    @input x::Vector{Float32}
    @input y::Vector{Float32}
    @input temperature::Float32 = 2f0

    @state buffers = make_buffers()

    apply_input(dynamics.model, x)
    apply_targets(dynamics.model, y)
    dynamics(T = temperature)
end
```

Prepare or construct with init-time data:

```julia
p = Process(
    algo,
    Init(:dynamics; model = graph),
    Init(:_state; buffers = buffers),
)
```

Run with runtime values:

```julia
run!(p; x, y)
run!(p; x = x2, y = y2, temperature = 1.5f0)
```

Equivalent lower-level shape:

```julia
bind!(p; x, y)
run(p)
```

## Validation Rules

Before the loop starts:

- all required runtime inputs must be present unless already/defaulted
- unknown runtime keywords should error
- annotated inputs should be converted or validated to the declared type
- repeated runs should preserve the concrete `_input` context shape
- type changes after first binding should error and point users to reinit or
  prepare again

The merge happens before precompile/spawn so generated code sees the final
context type for that run.

## Preparation Direction

`resolve(la)` should become a lower-level/internal structural step. The user API
should move toward:

```julia
prepared = prepare(la, Init(...))
run!(prepared; x, y)
```

Conceptual phases:

- `LoopAlgorithm`: source/specification
- resolved loop: registry, keys, routes, shares attached
- prepared loop: resolved loop plus initialized persistent context
- process/scheduler: prepared loop plus lifetime, task state, listeners, locks

This keeps `resolve` available for internals and inspection, while users learn
`prepare` and `run!`.

## Inspection

`inspect(la)` should make composition contracts visible without reading the full
source tree. It should report:

- declared LoopAlgorithm runtime inputs
- init requirements discovered by analysis
- persistent states and buffers
- registered algorithms and context keys
- routes and shares
- nested composition structure
- warnings where requirements are implicit or ambiguous

This is structural inspection, not performance profiling.

## Follow-Up Work

These items remain after the runtime input/init split and should be handled in
separate passes.

### `run!` For Initialized Loop Algorithms

Initialized loop algorithms should own their persistent context through a stable
context reference, e.g. `Ref{C}`. That makes `run!(la; kwargs...)` meaningful:
it can run with the referenced context, strip runtime-only fields from the
result, and write the persistent context back into the same reference.

Contract:

- `run(la; kwargs...)` remains functional and may return a loop algorithm whose
  context type changed.
- `run!(la; kwargs...)` mutates the existing context reference and must preserve
  the stored context type `C`.
- If the stripped persistent result is not assignable to `C`, `run!` should
  error and tell the caller to use `run(...)` or reinitialize.
- Runtime-only fields such as `:_input` and `process` are never written back by
  `run!`.

### Process Naming And Handles

The current `Process` type is the interactive/asynchronous process handle: it
owns runtime context, task state, pausing, resuming, listeners, and lifecycle
control. That role should be made explicit.

Planned direction:

- Introduce `InteractiveProcess` for the pausable runtime handle.
- Keep `Process(...)` as a compatibility constructor or alias during migration.
- Keep `InlineProcess` as the no-pausing synchronous handle.
- Keep direct initialized loop algorithms as the advanced low-level entrypoint
  for repeated runs and context reference mutation.

### Route-Aware Discovery Phase

Some process algorithms may need route-aware type discovery after lifecycle
`init` but before scheduled loop stepping. This should not expose bootstrap as
user API. Bootstrap remains loop-owned.

Planned direction:

- Add a small `@ProcessAlgorithm` API for route-aware discovery/type-shape
  declaration.
- Let algorithms declare or compute first-step value shapes without requiring
  their scheduled `step!` to run early.
- Keep transient discovery state discardable; it must not become persistent
  context unless explicitly initialized as state.
- Until this exists, delayed algorithms that expose values to consumers must
  initialize those values in persistent state or be wrapped so producers run
  before consumers.

### Generated And Threaded Loop Support

The current runtime-input and resume semantics are defined for the direct
non-generated loop path. Generated and threaded loops need a separate pass.

Planned direction:

- Add explicit `Resuming{isresuming}` handling to generated loops instead of
  forwarding to non-generated loops.
- Keep runtime input merging at the beginning of the loop path so the merged
  context type is visible before bootstrap.
- Preserve the same context rules: fresh runs perform the unsafe/bootstrap step,
  resumed runs skip it with an already-grown context, and steady-state steps
  preserve context type.
- Treat the existing threaded implementation as out of scope until it is brought
  back into the main API.
