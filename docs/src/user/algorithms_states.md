# [Algorithms and States](@id algorithms_states_user)

`StepAlgorithm` and `AlgoState` are the two main building blocks you compose into a process.

- Use `StepAlgorithm` for something that actively participates in the loop by implementing `StatefulAlgorithms.step!`.
- Use `AlgoState` for data that should be initialized into a subcontext and then shared or read by algorithms.

Both are process entities: values that the package knows how to place inside a
process. When a process is prepared, each entity gets a named part of the
process context. That named part is its **subcontext**.

User methods receive a view of the current subcontext, plus any routed or shared
values that were made visible to it. In normal code, treat that view like a
read-only input object. A step writes values back by returning them (see
[Returns and updates](#Returns-and-updates)).

## Lifecycle Hooks

The framework lifecycle is:

1. `init` phase
2. looped `step!` phase
3. `cleanup` phase

Order matters here: states are initialized first, then algorithms. Cleanup
follows the same order. This means an algorithm can read values prepared by an
earlier state if those values are routed or shared to it.

Two details from the implementation are worth knowing:

- `cleanup` runs on natural finite completion and when `close` stops a running
  process.
- `pause` stores the resumable context without cleanup. Closing a paused
  process runs cleanup before finalizing it.

There is no built-in `prepare!` hook in the current pipeline.
If you want a one-time preparation step, fold it into `init` or guard the first `step!` with a flag in state.

## Full Definitions

```julia
struct MyAlgo <: StepAlgorithm
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

A hand-written `step!` that returns a named tuple writes each name back where it lives: `x` above is the
algorithm's state, so returning it updates it. To return a value and write back separately, return a
`StepResult`:

```julia
function StatefulAlgorithms.step!(a::MyAlgo, context)
    x = context.x + a.gain
    return StepResult(2x, StateUpdates(; x))   # the value 2x; x is written back
end
StatefulAlgorithms.updated_names(::Type{MyAlgo}) = (:x,)   # the names in `StateUpdates`
```

`updated_names` tells the DSL which arguments the step writes back, so a block that passes a value of its own to
`x` gets the same checks as for a `@StepAlgorithm` (a warning unless the value is state or `@mutable`, an error for an
`@input`). `@StepAlgorithm` defines it from its `@update`s; a hand-written `step!` defines it itself, and without it
nothing is checked.

```julia
struct MyState <: AlgoState end

function StatefulAlgorithms.init(::MyState, context)
    return (; shared_buffer = Float64[])
end
```

## Macro Shortcuts

### `@StepAlgorithm`

`@StepAlgorithm` creates the struct and the needed `step!` methods from a
function signature.

```julia
@StepAlgorithm function Accumulate(x, gain)
    @update x = x + gain
end
```

You can still define `init` and `cleanup` manually for the generated type.

#### Returns and updates

A `@StepAlgorithm` body is a Julia function body: `return v` (or its last expression) is its return value,
which a block captures with `y = Accumulate(...)`. Assigning an argument (`x = x + gain`) only changes the
body's local `x`, as in any Julia function. To write an argument back, mark it with `@update`:

- `@update x` writes `x`'s value at the `return` back to where the algorithm read it: its `@managed` state,
  or the variable of the block passed as `x`.
- `@update x = v` (or `@update x += v`, ...) assigns and marks in one line; `@update x, y` marks several.
- A body that ends in `@update ...` returns `nothing`.
- Only arguments can be updated (positional, `@managed`, keyword).

```julia
@StepAlgorithm function Anneal(E, @managed(T = 1.0); rate = 0.999)
    @update T = T * rate        # the algorithm's state
    return E / T                # a value: `scaled = Anneal(E)` in a block
end
```

`updated_names(Anneal) == (:T,)`: the names an algorithm updates, read when a block is built. Passing a
value of the block to an updated argument changes it; see the composite DSL page for the rules.

#### Macro-Generated Algorithm Semantics

`@StepAlgorithm` also supports managed local state and configuration fields.
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
@StepAlgorithm begin
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
        @update metric = sum(buffer)   # `buffer` is changed in place; `metric` is written back
        return metric
    end
end
```

Rules worth knowing:

- `@managed(name)` captures `name` from the init context into local managed state.
- `@managed(name = expr)` evaluates `expr` during `StatefulAlgorithms.init`.
- `@managed(a, b = expr, c = expr2)` expands to multiple managed locals in order.
- `@input/@inputs/@init` may only appear once and must be the last keyword-like item.
- `@config` fields must have defaults and become fields on the generated struct.
  You can write them in a surrounding block or as a prelude like `@StepAlgorithm @config seed = 1 function MyAlgo(...) ... end`.
- inside the algorithm body, config fields are available directly by name.
  Use `seed`, not `config.seed`.
- plain positional arguments are runtime-only and are not available while constructing managed state.
- Julia `where` signatures are supported.

#### Supertype

The generated struct is a `StepAlgorithm`. To make it a subtype of your own abstract type (which must itself be a
`StepAlgorithm`), write `<: T` after the signature. With a `where` clause, put its parameters in braces
(`where {S} <: T`), since `where S <: T` is a bound on `S`.

```julia
abstract type MonteCarloAlgorithm <: StepAlgorithm end

@StepAlgorithm @inline function Metropolis(spins, T, @managed(rng = Xoshiro(1))) <: MonteCarloAlgorithm
    # ...
end
```

#### Inlining the body

By default Julia decides whether the algorithm body is inlined into the plan's step. That is
the right choice for small bodies (always inlined) and large ones (compiled once and reused by every
plan). A medium-sized kernel that runs for only a few nanoseconds per step, such as a single-spin
Metropolis update, can fall in between: the compiler's size-based heuristic does not know the call
sits in a hot loop, and the call then costs about 1 ns per step. Write `@inline` on the function to
force the body into the plan:

```julia
@StepAlgorithm @inline function Metropolis(spins, T, @managed(rng = Xoshiro(1)))
    # ...
end
```

This also works after `@config` and in the block form. The cost is compile time: a forced body is
compiled again inside every plan that contains the algorithm.

For a macro-generated algorithm `MyAlgo`, the main entrypoints are:

- direct/bootstrap call: `step!(MyAlgo(), args...; @inputs((; ...)))`
- init hook: `StatefulAlgorithms.init(MyAlgo(), context)`
- step hook: `StatefulAlgorithms.step!(MyAlgo(), context)`

Internally the macro defines:

- `struct MyAlgo <: StepAlgorithm end` or `Base.@kwdef struct MyAlgo ... end`
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

### `@AlgoState`

`@AlgoState` creates a `AlgoState` and an `init` method.

```julia
@AlgoState function SharedParams(dt)
    return (; dt)
end
```

## Composition

Compose entities with loop plans:

- `CompositeAlgorithm(...)` for interleaved stepping with intervals.
- `Routine(...)` for sequential blocks with repeats.

Both take `AlgoState`s, wiring (`Route`, `Share`) and options (`RuntimeInputs`, `Replace`) after the children
and their schedule. A plan keeps the three apart: `getstates`, `getwiring` (with `get_routes` and `get_shares`) and
`getoptions`.

### Changing a Loop Algorithm Schedule

Process `lifetime` controls how long the outer process loop runs. Inside a
loop plan, the per-child schedule is controlled by the plan itself:

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

Composite schedules can also be conditional:

```julia
algo = CompositeAlgorithm(
    Logger,
    (RunIf(Interval(10), x -> x > 0, Var(Source, :value)),),
)
```

`RunIf(cond, vars...)` defaults to every tick. `RunIf(interval, cond, vars...)`
combines interval scheduling with a context predicate. A skipped child leaves
its previous persistent state unchanged.

These helpers return a new plan with the updated schedule. They are intended
for unresolved plans; if you already called `resolve`, edit the original plan
and resolve it again.

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
