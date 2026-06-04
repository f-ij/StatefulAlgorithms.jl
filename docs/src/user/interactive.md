# [Interactive Contexts](@id interactive_user)

`ContextExchange` gives external code a polled read/write handle to selected
process variables.

## Selectors

Add a `ContextExchange` child and pass its `Var` selectors as init-only
`vars`:

```julia
algo = resolve(CompositeAlgorithm(
    :target => MyAlgo(),
    :_exchange => ContextExchange(),
    (1, 20),
))

context = StatefulAlgorithms.context(init(
    algo,
    Init(:_exchange; vars = (Var(:target, :value), Var(:target, :seen))),
))
```

Selectors are resolved during `initcontext`, when the registry and concrete
state layout are available. The resolved paths are stored in the exchange state
type, and `ContextExchange` uses a custom `_step!` instead of route/wiring
machinery.

For a different external name, use a pair:

```julia
Init(:_exchange; vars = (:display => Var(:target, :value),))
```

Type selectors are also supported when they resolve uniquely:

```julia
Init(:_exchange; vars = (:display => Var(MyAlgo, :value),))
```

## Polling And Writes

External code reads and writes exchange-local names:

```julia
ref = view(context, :value)
ref[]          # last published value, initialized from the target field
ref[] = 4      # queued write
```

The next due exchange step converts pending writes to the current target field
type and writes directly into the resolved subcontext. Current values are also
published to the ref slots on due exchange steps.

Programmatic writes use the same names:

```julia
interact!(context, :value => 5)
interact!(process, :value => 5)
```

Default lookup expects one `ContextExchange` in the process. If there are
multiple exchanges, pass the exchange key explicitly.

## Scheduling

The outer loop schedule still controls how often the exchange child is called:

```julia
CompositeAlgorithm(target, :_exchange => ContextExchange(), (1, 20))
StatefulAlgorithms.context(init(algo, Init(:_exchange; vars = (Var(:target, :value),))))
```

The exchange also supports a wall-clock gate:

```julia
ContextExchange(; period = 0.05)
Init(:_exchange; vars = (Var(:target, :value),))
```

If the exchange is called before `period` seconds have elapsed, it returns
without reading selected variables or applying pending writes.

## Complete Example

```julia
using StatefulAlgorithms

struct InteractiveTarget <: ProcessAlgorithm end

function StatefulAlgorithms.init(::InteractiveTarget, context)
    return (; value = 1.0)
end

function StatefulAlgorithms.step!(::InteractiveTarget, context)
    return (;)
end

algo = resolve(CompositeAlgorithm(
    :target => InteractiveTarget(),
    :_exchange => ContextExchange(),
    (1, 1),
))

context = StatefulAlgorithms.context(init(
    algo,
    Init(:_exchange; vars = (Var(:target, :value),));
    lifetime = Repeat(3),
))
ref = view(context, :value)

ref[] == 1.0

ref[] = 4
context = StatefulAlgorithms._step!(algo, context, StatefulAlgorithms.Stable())

ref[] == 4.0
context.target.value == 4.0
```

The interactive API is covered in `test/ContextExchangeTest.jl`.
