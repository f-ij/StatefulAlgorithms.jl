# [Interactive Contexts](@id interactive_user)

The package has two interactive mechanisms with different timing semantics:

1. `Interactive(...)` stores selected persistent fields in immediate mutable
   `InteractiveVar` wrappers.
2. During plan-driven execution, `ContextExchange` queues external writes and
   publishes reads when its scheduled child step is due.

## Immediate Lifecycle Variables

Pass `Interactive(target, names...)` as a lifecycle option when coordinated
in-process code should mutate selected fields directly:

```julia
initialized = init(
    algo,
    Override(:target; value = 3.0),
    Interactive(:target, :value),
)

ctx = context(initialized)
value_ref = ctx.target.value
value_ref[] = 4.0
```

The wrapper is applied after `init` and `Override`, so the example starts at
`3.0`. Lifecycle methods read `context.value` as the contained `Float64`, and a
returned `(; value = new_value)` writes through the existing wrapper. External
code sees the stored `InteractiveVar` and can read or assign it with `[]`.

This mechanism changes the value immediately and provides no scheduler boundary
or cross-task synchronization contract. Use it when the caller coordinates
access. Use `ContextExchange` when updates should be applied at explicit plan
steps.

## Scheduled Context Exchange

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

Selectors are resolved during lifecycle initialization, when the registry and
concrete state layout are available. The resolved paths are stored in the
exchange state type, and `ContextExchange` uses a custom `_step!` instead of
route/wiring machinery.

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

Each external write is converted immediately to the selected target field type
and queued. The next due exchange step writes that typed pending value into the
resolved subcontext. Current values are also published to the ref slots on due
exchange steps.

Programmatic writes use the same names:

```julia
interact!(context, :value => 5)
interact!(process, :value => 5)
```

Default lookup expects one `ContextExchange` in the process. If there are
multiple exchanges, pass the exchange key explicitly.

```julia
ref = view(context, :display; exchange = :dashboard_exchange)
```

The compatibility form `view(context, Var(:dashboard_exchange, :display))`
means the same thing here. In that overload, the first `Var` argument names the
exchange, not the target subcontext originally selected during `Init`.

## Scheduling

The outer loop schedule still controls how often the exchange child is called:

```julia
algo = resolve(CompositeAlgorithm(
    :target => target,
    :_exchange => ContextExchange(),
    (1, 20),
))
context = StatefulAlgorithms.context(init(
    algo,
    Init(:_exchange; vars = (Var(:target, :value),)),
))
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

struct InteractiveTarget <: StepAlgorithm end

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

initialized = init(
    algo,
    Init(:_exchange; vars = (Var(:target, :value),));
    lifetime = Repeat(3),
)
process = Process(initialized; repeats = 1)
ref = view(context(process), :value)

ref[] == 1.0

ref[] = 4
run(process)
wait(process)

ref[] == 4.0
context(process).target.value == 4.0
```
