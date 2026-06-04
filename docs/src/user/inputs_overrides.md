# [Init, Overrides, and Runtime Inputs](@id inputs_overrides_user)

Initialization specs and runtime inputs solve different problems.

- `Init(...)` provides values used while building persistent context.
- `Override(...)` force-replaces initialized persistent context values.
- DSL `@input` declares per-run values supplied as `run(...; kwargs...)`.

`Input(...)` is still accepted as a compatibility alias for `Init(...)`.

## Init and Override Specs

`Init` and `Override` target one algorithm or state. Use the same reference
style you used when adding that target to the composition: the type, the saved
instance, a saved `Unique(...)` value, or an explicit symbol key.

## API

```julia
Init(target; name = value, ...)
Override(target; name = value, ...)
```

Pair syntax is also accepted:

```julia
Init(target, :name => value)
Override(target, :name => value)
```

Targets are resolved through the composed algorithm registry: the table of
registered algorithms and states for the final process. After resolving, the
target namespace is stored in the spec type and the matched registry entry is
kept as `ref` for display and inspection.

## When They Apply

`init(la, specs...)` applies persistent setup in this order:

1. `Init` specs are merged into target subcontexts.
2. `init(...)` executes.
3. `Override` specs are merged after init.

So:

- `Init` is for values needed during initialization.
- `Override` force-replaces initialized values.

## Stored Lifecycle Specs

Initialized loop algorithms store their `Init` and `Override` specs. Calling
`init(la)` again replays the stored specs and rebuilds the full persistent
context.

Passed specs override stored specs per target:

```julia
initialized = init(algo, Init(Walker; dt = 0.01))
updated = init(initialized, Init(Walker; dt = 0.02))
```

`partialinit(la, specs...)` rebuilds only the targeted algorithms or states:

```julia
la = partialinit(la, Init(Walker; dt = 0.02))
```

Both `init` and `partialinit` return a loop algorithm. Callers should use the
returned value because the concrete context type may change.

## Example

```julia
algo = CompositeAlgorithm(Walker, InsertNoise, (1, 2))

p = Process(
    algo,
    Init(Walker; dt = 0.01),
    Override(InsertNoise; seed = 1234),
    repeats = 100,
)
```

Use `repeats = 100` for a fixed number of process loop iterations, or
`lifetime = Repeat(100)` if you want to pass the lifetime object explicitly.

## Targeting and Identity

When choosing targets, use the same references you used in composition.

For exact patterns and examples, see [Referencing Algorithms](@ref referencing_algorithms_user).

## Runtime `@input`

Runtime inputs are declared on a `@CompositeAlgorithm` or `@Routine` with
`@input`. They are passed as keyword arguments to `run`, validated before loop
execution, and merged into the transient `ProcessContext._input` field for that
run only.

```julia
algo = @CompositeAlgorithm begin
    @state energy = 0.0
    @input temperature::AbstractFloat
    @input sweep = 1

    step = metropolis(energy, temperature; sweep = sweep)
end

la = init(resolve(algo))
la = run(la; temperature = 2.0)
```

Runtime inputs are not stored in the loop algorithm. After the run finishes,
the stored persistent context excludes runtime `_input` values.

Input declarations support:

```julia
@input required_name
@input typed_name::AbstractFloat
@input defaulted_name = 1
```

Rules:

- Required inputs must be passed to `run`.
- Unknown runtime keyword arguments are rejected.
- Typed inputs are checked with `isa`.
- Defaults are used when defaulted inputs are omitted.

For a `Process`, pass the same runtime inputs to `run`:

```julia
p = Process(algo; repeats = 100)
run(p; temperature = 2.0)
```
