# [Algorithms and States](@id algorithms_states_user)

`ProcessAlgorithm` and `ProcessState` are the two main building blocks you compose into a process.

- Use `ProcessAlgorithm` for something that actively participates in the loop by implementing `StatefulAlgorithms.step!`.
- Use `ProcessState` for data that should be initialized into a subcontext and then shared or read by algorithms.

Both are process entities: values that the package knows how to place inside a
process. When a process is prepared, each entity gets a named part of the
process context. That named part is its **subcontext**.

User methods receive a view of the current subcontext, plus any routed or shared
values that were made visible to it. In normal code, treat that view like a
read-only input object. Return a `NamedTuple` to write values back.

## Lifecycle Hooks

The framework lifecycle is:

1. `init` phase
2. looped `step!` phase
3. `cleanup` phase

Order matters here: states are initialized first, then algorithms. Cleanup
follows the same order. This means an algorithm can read values prepared by an
earlier state if those values are routed or shared to it.

Two details from the implementation are worth knowing:

- `cleanup` runs on natural finite completion.
- If a process is interrupted, paused, or runs under `Indefinite()`, the current context is stored without automatic cleanup.

There is no built-in `prepare!` hook in the current pipeline.
If you want a one-time preparation step, fold it into `init` or guard the first `step!` with a flag in state.

## Full Definitions

```julia
struct MyAlgo <: ProcessAlgorithm
    gain::Float64
end

function StatefulAlgorithms.init(a::MyAlgo, context)
    x = 0.0
    return (; x)
end

function StatefulAlgorithms.step!(a::MyAlgo, context)
    (; x) = context
    x = x + a.gain
    return (; x)
end

function StatefulAlgorithms.cleanup(::MyAlgo, context)
    return (;)
end
```

```julia
struct MyState <: ProcessState end

function StatefulAlgorithms.init(::MyState, context)
    return (; shared_buffer = Float64[])
end
```

## Macro Shortcuts

### `@ProcessAlgorithm`

`@ProcessAlgorithm` creates the struct and the needed `step!` methods from a
function signature.

```julia
@ProcessAlgorithm function Accumulate(x, gain)
    x = x + gain
    return (; x)
end
```

You can still define `init` and `cleanup` manually for the generated type.

#### Macro-Generated Algorithm Semantics

`@ProcessAlgorithm` also supports managed local state and configuration fields.
Managed local state is data that belongs to one algorithm and is created during
`init`, then read again during each `step!`.

The signature is split into:

- plain positional arguments: values read from context during `StatefulAlgorithms.step!`
- `@managed(...)` positional arguments: algorithm-owned values created during `StatefulAlgorithms.init`
- normal keyword arguments: values read from context during `StatefulAlgorithms.step!`, using the declared default when absent
- optional trailing `@input((; ...))` / `@inputs((; ...))` / `@init((; ...))`: values read only while constructing managed state
- optional `@config ...` declarations before the function: fields stored on the generated algorithm object

Example:

```julia
@ProcessAlgorithm begin
    @config n::Int = 8
    @config damp = 1.0

    function MyAlgo(
        signal,
        @managed(buffer = zeros(n)),
        @managed(scale),
        @managed(metric = 0.0);
        @inputs((; scale = 2.0))
    )
        @inbounds for i in eachindex(signal)
            buffer[i] = damp * scale * signal[i]
        end
        metric = sum(buffer)
        return (; buffer, scale, metric)
    end
end
```

Rules worth knowing:

- `@managed(name)` captures `name` from the init context into local managed state.
- `@managed(name = expr)` evaluates `expr` during `StatefulAlgorithms.init`.
- `@managed(a, b = expr, c = expr2)` expands to multiple managed locals in order.
- `@input/@inputs/@init` may only appear once and must be the last keyword-like item.
- `@config` fields must have defaults and become fields on the generated struct.
  You can write them in a surrounding block or as a prelude like `@ProcessAlgorithm @config seed = 1 function MyAlgo(...) ... end`.
- inside the algorithm body, config fields are available directly by name.
  Use `seed`, not `config.seed`.
- plain positional arguments are runtime-only and are not available while constructing managed state.
- Julia `where` signatures are supported.

For a macro-generated algorithm `MyAlgo`, the main entrypoints are:

- direct/bootstrap call: `step!(MyAlgo(), args...; @inputs((; ...)))`
- init hook: `StatefulAlgorithms.init(MyAlgo(), context)`
- step hook: `StatefulAlgorithms.step!(MyAlgo(), context)`

Internally the macro defines:

- `struct MyAlgo <: ProcessAlgorithm end` or `Base.@kwdef struct MyAlgo ... end`
- a hidden implementation function containing the user body
- public `StatefulAlgorithms.step!(algo::MyAlgo, ...)` methods for direct calls
- generated `StatefulAlgorithms.init` and `StatefulAlgorithms.step!` methods that feed the implementation

Type annotations and `where` clauses are preserved on the generated public call signatures and
the hidden implementation function. The runtime context extraction methods currently bind simple
locals before forwarding into that typed implementation.

#### Analysis-Friendly Forms

If you want `ContextAnalyser` to discover dependencies more reliably:

- use `@inputs((; ...))` to make init-time requirements explicit
- use `context.name` or `(; name) = context` for required reads
- use `get(context, :name, default)` for optional reads
- return plain `NamedTuple`s from `init` and `step!`

See [Init Analysis](@ref init_analysis_user) for the analyzer workflow and limitations.

### `@ProcessState`

`@ProcessState` creates a `ProcessState` and an `init` method.

```julia
@ProcessState function SharedParams(dt)
    return (; dt)
end
```

## Composition

Compose entities with loop algorithms:

- `CompositeAlgorithm(...)` for interleaved stepping with intervals.
- `Routine(...)` for sequential blocks with repeats.

Both can include `ProcessState`s and user options such as `Route` and `Share`.

### Changing a Loop Algorithm Schedule

Process `lifetime` controls how long the outer process loop runs. Inside a
loop algorithm, the per-child schedule is controlled by the loop algorithm
itself:

- `CompositeAlgorithm` and `ThreadedCompositeAlgorithm` use intervals.
- `Routine` uses repeats.

For composite algorithms, use the edit helpers before resolving the algorithm:

```julia
algo = CompositeAlgorithm(FastStep, SlowStep, (1, 10))

algo = changeinterval(algo, 2, 20)
interval(algo, 2) == StatefulAlgorithms.Interval(20)

algo = changeintervals(algo, (1, 5))
intervals(algo) == (StatefulAlgorithms.Interval(1), StatefulAlgorithms.Interval(5))
```

These helpers return a new loop algorithm with the updated schedule. They are
intended for unresolved loop algorithms; if you already called `resolve`, edit
the original algorithm and resolve it again.

When adding a child, pass the new child's schedule as the last argument:

```julia
algo = addalgo(algo, :logger => Logger, 100)
```

For `Routine`, the constructor and `addalgo` schedule argument are repeat
counts:

```julia
routine = Routine(Prepare, Train, (1, 50))
routine = addalgo(routine, :validate => Validate, 1)
```
