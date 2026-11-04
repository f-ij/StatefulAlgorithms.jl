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

`setup(plan_spec, specs...)` (and process construction, which runs it) applies persistent setup in this order:

1. `Init` specs are merged into target subcontexts.
2. `init(...)` executes.
3. `Override` specs are merged after init.

So:

- `Init` is for values needed during initialization.
- `Override` force-replaces initialized values.

## Stored Lifecycle Specs

A plan holds no specs and no context. `setup` returns the context, and the user keeps
it; a process keeps the specs it was built with and sets up from them again on a
full `reinit(p)`. Several specs for one target in one call are merged, later ones win:

```julia
context, plan = setup(algo, Init(Walker; dt = 0.01), Init(Walker; dt = 0.02))   # dt == 0.02
```

`reinit(plan, context, specs...)` rebuilds only the targeted algorithms or states
and keeps the rest of the context:

```julia
context = reinit(plan, context, Init(Walker; dt = 0.02))
```

See [The Pipeline: Setup, Run, Cleanup](@ref pipeline_user).

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
execution, and are the run's read-only inputs (`_inputs`) for that run only.

```julia
algo = @CompositeAlgorithm begin
    @state energy = 0.0
    @input temperature::AbstractFloat
    @input sweep = 1

    step = metropolis(energy, temperature; sweep = sweep)
end

context, plan = setup(algo)
context, _ = run(plan, context; temperature = 2.0)
```

Runtime inputs are not stored in the context. After the run finishes, the
returned context excludes runtime `_inputs` values.

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
