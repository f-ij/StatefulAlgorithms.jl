# [Composite DSL](@id composite_dsl_user)

The composite DSL builds `CompositeAlgorithm` and `Routine` values from a block
syntax. It is a constructor shorthand: entries still become normal algorithms,
states, routes, shares, and schedules.

Use `@CompositeAlgorithm` when child entries should run on interval schedules.
Use `@Routine` when child entries should run sequentially with repeat counts.

```julia
algo = @CompositeAlgorithm begin
    @state seed = 3
    @alias source = SourceAlgo

    produced, passthrough = source(seed = seed)
    doubled = @interval 10 double(produced)
    Sink(value = doubled)
end
```

## Inline State

Declare local state with `@state`.

```julia
algo = @Routine begin
    @state equilibrium_state
    @state clamping_beta = 0.0
    @state buffers = Float64[]

    Step(value = clamping_beta)
end
```

Fields without defaults are required during init. Fields with defaults are
rebuilt for each process initialization.

You can also give the inline state an explicit key:

```julia
algo = @CompositeAlgorithm begin
    @state learning_state begin
        loss = 0.0
        buffer = Float64[]
    end

    Logger(value = loss)
end
```

## Runtime Inputs

Declare per-run values with `@input`.

```julia
algo = @CompositeAlgorithm begin
    @state energy = 0.0
    @input temperature::AbstractFloat
    @input sweep = 1

    accepted = metropolis_step(energy, temperature; sweep = sweep)
end
```

Runtime inputs are supplied to `run` as keyword arguments:

```julia
p = Process(algo; repeats = 100)
run(p; temperature = 2.0)
```

They are validated once before the loop starts and are visible during the run
through the transient `ProcessContext._input` field. They are not stored in the
initialized loop algorithm or finished process context after the run.

Forms:

```julia
@input required_name
@input typed_name::AbstractFloat
@input defaulted_name = 1
```

Use runtime `@input` for scalar parameters or small values that can change from
run to run. Use `@state` or `Init(...)` for persistent buffers and setup data.

## Aliases

Use `@alias` to name an algorithm constructor or value for later DSL entries.

```julia
algo = @Routine begin
    @alias dynamics = Metropolis(model)
    @alias capture = Capturer()

    state = dynamics()
    capture(value = state)
end
```

Aliases are macro-time names. They affect later uses of the alias in the DSL;
they are not runtime variables.

## Function Calls

Plain Julia function calls are wrapped in a small process algorithm.

```julia
algo = @Routine begin
    @state x = 2
    y = sqrt(x)
    z = scale_value(y; scale = 3)
end
```

Known DSL names such as `x` and `y` are routed from context. Other Julia values
are captured into the wrapper.

## Algorithm Routes

Keyword arguments to process algorithms are route declarations.

```julia
algo = @CompositeAlgorithm begin
    @state seed = 3
    produced = Source(seed = seed)
    Sink(value = produced)
end
```

`Sink(value = produced)` routes `produced` into the target as `value`.

Process algorithms created with `@ProcessAlgorithm` can also use direct
positional syntax when their positional argument names are known:

```julia
algo = @Routine begin
    @state value = 1
    MyGeneratedAlgo(value)
end
```

## Transform Routes

Use explicit `@transform(f, source)` when a routed value should be transformed
before it reaches the target.

```julia
algo = @Routine begin
    @state clamping_beta = 2.0
    SetBeta(value = @transform(x -> -x, clamping_beta))
end
```

The source can be a normal DSL symbol or an owned-field reference:

```julia
algo = @CompositeAlgorithm begin
    @context c = nested()
    result = identity(@transform(x -> x + 1, c.capture.value))
end
```

Transforms are route syntax, not general Julia expression syntax. Write
`@transform(x -> -x, clamping_beta)`, not `-clamping_beta`, when the value must
come from the process context.

Use an explicit `@route` statement when a transformed route also needs writeback
through a reverse transform:

```julia
algo = @CompositeAlgorithm begin
    @alias source = SourceAlgo
    @alias target = TargetAlgo

    source()
    target()

    @route source.value => target.input transform = x -> 2x reverse_transform = y -> y / 2
end
```

Here `target` reads `input` through the forward transform. If it returns
`(; input = new_input)`, the source field `value` is updated through
`reverse_transform`.

`@transform(f, source)` is read-transform syntax for call arguments. Reverse
writeback uses `@route ... reverse_transform = g`.

## Ref and Indexed Reads

Indexed reads from context values are routed as transform routes.

```julia
algo = @CompositeAlgorithm begin
    @state clamping_beta = Ref(2.0)
    Sink(value = clamping_beta[])
end
```

This routes `clamping_beta` and applies `getindex` before the target sees it.
The same shape works with indexes and ranges:

```julia
algo = @Routine begin
    @state buffer = [1, 2, 3]
    first_value = identity(buffer[1])
    tail = identity(buffer[2:3])
end
```

## Direct State Writes

Assigning a captured Julia value to an inline state field lowers to a
`ContextWrite` widget.

```julia
somevar = 3

algo = @Routine begin
    @state clamping_beta = 1.0
    clamping_beta = somevar
end
```

The assignment captures `somevar` when the loop algorithm is constructed. At
step time, the value is converted to the current context field type when the
field already exists.

If the right-hand side is a context value, route it explicitly through normal
DSL syntax:

```julia
algo = @Routine begin
    @state source = 2.0
    @state target = 0.0
    target = source
end
```

## Indexed Mutation

Use normal indexed assignment to mutate buffers stored in context.

```julia
algo = @Routine begin
    @state buffer = [0, 0, 0]

    buffer[1] = 2
    buffer[2:3] = [4, 5]
end
```

This lowers to a wrapped `setindex!` call. The buffer itself is routed from the
context, then mutated in place.

Indexes may be literals, variables captured from the surrounding Julia scope, or
ranges:

```julia
idx = 2

algo = @Routine begin
    @state buffer = [0, 0, 0]
    buffer[idx] = 9
end
```

## Broadcast Mutation

Broadcast assignment is also supported for context buffers.

```julia
replacement = [7, 8]

algo = @Routine begin
    @state buffer = [0, 0, 0]

    buffer .= 1
    buffer[2:3] .= replacement
end
```

Whole-buffer broadcast lowers to `context_broadcast!(buffer, value)`.
Indexed broadcast lowers through `view(buffer, inds...)`, so range writes mutate
the original buffer rather than a copied slice.

## Owned Field Reads

Use dotted references to read fields owned by aliased algorithms or nested
contexts.

```julia
algo = @Routine begin
    @alias dynamics = Dynamics()

    seen = Sink(value = dynamics.state)
    state = dynamics()
end
```

The special binding form:

```julia
state = dynamics.state
```

exposes the owned field under the plain DSL name `state` for later statements.

## Owned Field Writes

You can assign to an owned field target.

```julia
nudged = @Routine begin
    @state nudged_beta = 0.0
    Step(beta = nudged_beta)
end

algo = @CompositeAlgorithm begin
    @state clamping_beta = Ref(2.0)
    @alias nudged = nudged

    nudged.nudged_beta = clamping_beta[]
    nudged()
end
```

This creates a `ContextWrite` entry and routes the assigned value into it. For a
nested routine's inline state, the write targets the nested state field through
the normal route and merge machinery.

## Explicit State Sharing

Nested DSL blocks can independently declare the same state field. That remains
compatible, but the merge now warns unless the parent documents the intended
sharing.

Use `@bind` when the parent block owns, defaults, or requires the shared state
and a child block should use that same slot.

```julia
@bind buffers => f.buffers
```

This says: the current block's `buffers` state slot and child context `f`'s
inline `buffers` state slot are intentionally the same resource.

```julia
forward = @Routine begin
    @state buffers
    buffers = fill_forward!(buffers)
end

nudged = @Routine begin
    @state buffers
    buffers = read_nudged!(buffers)
end

algo = @CompositeAlgorithm begin
    @state buffers = make_buffers()

    @context f = forward()
    @context n = nudged()

    @bind buffers => f.buffers
    @bind buffers => n.buffers
end
```

In this example, `algo` creates the buffer with `make_buffers()`. Both child
routines declare `@state buffers` because each routine is still a reusable
building block with a local contract, but the parent explicitly binds both child
contracts to the parent-owned state slot.

Use `@merge` when child blocks should share with each other and the parent does
not need to declare a separate state slot:

```julia
@merge f.buffers, n.buffers
```

This says: child context `f`'s inline `buffers` slot and child context `n`'s
inline `buffers` slot are intentionally the same resource.

```julia
algo = @CompositeAlgorithm begin
    @context f = forward()
    @context n = nudged()

    @merge f.buffers, n.buffers
end
```

If neither child supplies a default, the merged field remains required:

```julia
algo = @CompositeAlgorithm begin
    @context f = forward()
    @context n = nudged()

    @merge f.buffers, n.buffers
end

resolved = resolve(algo)
initialized = init(resolved, Init(:_state; buffers = make_buffers()))
```

If one side has a default and the other side is required, the default satisfies
the merged slot:

```julia
forward_with_default = @Routine begin
    @state buffers = make_buffers()
    buffers = fill_forward!(buffers)
end

algo = @CompositeAlgorithm begin
    @context f = forward_with_default()
    @context n = nudged()

    @merge f.buffers, n.buffers
end
```

If multiple merged slots provide defaults for the same field, construction still
continues but warns because the later default wins. Prefer a single parent
default with `@bind` when ownership is clear.

Selectors are written against `@context` aliases and must appear after the
context has been declared:

```julia
algo = @CompositeAlgorithm begin
    @context f = forward()
    @context n = nudged()

    @merge f.buffers, n.buffers
end
```

`f.buffers` is transparent syntax for the nested inline state field
`f._state.buffers`; both forms are accepted:

```julia
@merge f._state.buffers, n.buffers
@bind buffers => f._state.buffers
```

Use `@bind` for parent-to-child sharing. Use `@merge` for peer child-to-child
sharing. Without either declaration, overlapping child state fields are still
merged for compatibility, but the DSL warns with paths such as
`f.buffers <=> n.buffers` and suggests an explicit `@bind` or `@merge`.

## Context Aliases

Use `@context` when later statements need to refer to the subcontext produced by
a nested DSL entry.

```julia
plus = @Routine begin
    @alias capture = Capturer()
    capture()
end

algo = @CompositeAlgorithm begin
    @context c1 = plus()
    result = identity(c1.capture.value)
end
```

`@context` is only a macro-time reference. The wrapped entry still runs as the
right-hand side expression says.

## Full-Context Shares

Use `@all(source)` or `@all(source...)` in an algorithm call to lower to a
normal `Share`.

```julia
algo = @CompositeAlgorithm begin
    @alias source = Source
    source()
    Consumer(@all(source...))
end
```

## Scheduling

Inside `@CompositeAlgorithm`, use `@interval` or `@every` on the right-hand side
of an entry.

```julia
algo = @CompositeAlgorithm begin
    @state value = 1
    sampled = @interval 10 Sample(value)
end
```

Inside `@Routine`, use `@repeat`.

```julia
routine = @Routine begin
    @state value = 1
    value = @repeat 5 Step(value = value)
end
```

`@repeat` also accepts the normal lifetime constructors. When a lifetime selector
is written as a DSL variable, the DSL resolves it to the corresponding `Var(...)`
selector:

```julia
routine = @Routine begin
    count = @repeat Until(x -> x >= 100, count) Counter()
end
```

Supported forms are `Repeat(n)`, `Indefinite()`, `Until(condition, selector)`,
`RepeatOrUntil(condition, n, selector)`, `AtLeast(condition, n, selector)`, and
`AtLeastAtMost(condition, min, max, selector)`.

For repeated sub-blocks:

```julia
algo = @CompositeAlgorithm begin
    @state value = 1

    result = @repeat 3 begin
        value = Step(value = value)
        value = Step(value = value)
    end
end
```

Write schedules on the right-hand side:

```julia
value = @interval 10 Step(value = value)
```

not:

```julia
@interval 10 value = Step(value = value)
```

## Conditional Entries

Use `@include_if` to include or skip entries when constructing the loop
algorithm.

```julia
algo = @CompositeAlgorithm begin
    @state seed = 3
    @include_if include_source produced = Source(seed = seed)
    Sink(value = seed)
end
```

The condition is evaluated at construction time. Skipped entries are not
registered and do not contribute routes, shares, or schedules.

## Final Post-Processing

Use one root-level `@finally` to wrap the outer algorithm with a final
post-processing function.

```julia
algo = @CompositeAlgorithm begin
    @state seed = 8
    Sink(value = seed)
    @finally summarize_context
end
```

`@finally` is only valid at the outer DSL block level.
