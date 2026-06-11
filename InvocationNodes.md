# Invocation Nodes

## Motivation

`FuncWrapper` already captures an important distinction: one Julia implementation
can be applied at many different places in a process graph with different input
selectors, output names, keys, and identities. For example, `sum(a, b, c)` and
`sum(a, c)` should not require two algorithm implementations. They are two
invocations of the same implementation.

The goal of an invocation abstraction is to make this distinction explicit:

- implementation: the function or algorithm object that does the work
- invocation: one scheduled use of that implementation in a process graph
- state binding: the unique or shared state owned by this invocation
- routing: the graph-level mapping from named values to invocation inputs
- return policy: which returned values update state, become transient emissions,
  or are persisted for observers/finalizers

## Relation To `FuncWrapper`

On `main`, `FuncWrapper` already has most of the necessary shape:

```julia
FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs, T, Id, Aliases, AlgoName, Key}
```

This corresponds roughly to:

- `F`: reusable implementation
- `InputSymbols`: positional input selectors
- `OutputSymbols`: output mapping
- `Kwargs`: keyword input/literal captures
- `Id`: invocation identity
- `Key`: context namespace

So `FuncWrapper` is already an invocation node for stateless function calls.
The missing generalization is first-class state binding and a clearer separation
between persistent state updates and transient returned values.

## Proposed Shape

Conceptually:

```julia
Invocation(
    implementation;
    inputs,
    kwargs = (;),
    outputs = (),
    state = NoState(),
    emits = (),
    key = AutoKey(),
    id = SimpleId(),
)
```

The fields should absorb their types into the invocation type parameters, as
with the existing `FuncWrapper` design. The value should primarily carry runtime
literals and display/debug data.

Possible state bindings:

```julia
NoState()
UniqueState(init_spec)
SharedState(:some_context_key)
```

This does not require every rich algorithm to become a plain function. Algorithm
objects like `Metropolis()` and `LocalLangevin(...)` can still be the
implementation, while the invocation records where their inputs and state come
from in this particular graph.

## Return Policy

The main semantic change should be:

> A returned field is a produced value, not automatically persistent state.

A defensible default:

- fields declared by `init` are persistent state
- returned fields matching persistent state update that state
- returned fields not matching persistent state are transient emissions
- routes, observers, finalizers, or explicit retention can demand emissions
- demanded emissions are addressable during scheduled execution
- undemanded emissions are not committed to persistent process state

This keeps diagnostics such as `DeltaE` or `acceptance_rate` available for
composition without forcing them to be loop-carried persistent state in every
composition.

## Runtime View

The resolved process graph can expose one addressable namespace while storing
values on different planes:

- persistent state
- runtime inputs
- transient invocation emissions
- observer/logger state
- process metadata

Routes can refer to all addressable values. The storage plane determines whether
a value survives loop iterations, is only available during a scheduled step, or
is committed after cleanup.

## Why This Is Not Just Normal Julia Functions

Normal Julia functions do not encode enough composition metadata by themselves.
The process graph still needs to know:

- which named values become positional arguments
- which state instance is used
- whether state is unique or shared
- when the invocation runs in a composite schedule
- where outputs are written
- whether returned fields are transient or persistent

Invocation nodes are therefore the graph-level call sites. They allow normal
Julia implementations to remain reusable while giving the process runtime the
metadata it needs for scheduling, routing, resuming, and state isolation.

## Design Direction

The likely path is not to replace `FuncWrapper`, but to promote its concept:

- keep `FuncWrapper` as the stateless/simple-call specialization or constructor
- add state binding and return policy to the general invocation model
- let composite DSL calls lower to invocation nodes
- keep rich `ProcessAlgorithm` objects for algorithms that benefit from dispatch
  and stored algorithm parameters
- use invocation metadata to lower hot loops to compact runtime frames instead
  of carrying every returned value as persistent context state

