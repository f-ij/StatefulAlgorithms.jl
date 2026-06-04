# [Value Semantics and `Unique`](@id value_semantics_user)

Most users only need one rule here:

- if you use the same algorithm type once, plain types or instances are fine;
- if you need multiple logically distinct instances of the same algorithm, use `Unique(...)` and keep the returned value around.

`Unique` exists to give one inserted algorithm a guaranteed separate identity in the registry and therefore a separate subcontext in the process context.

## When You Need `Unique`

You usually need `Unique(...)` when you want more than one copy of the same algorithm in a composition and you need to target them separately in:

- `Route(...)`
- `Share(...)`
- `Input(...)`
- `Override(...)`
- `Var(...)`

Example:

```julia
producer_a = Producer()
producer_b = Unique(Producer())
consumer = Consumer()

algo = CompositeAlgorithm(
    producer_a, producer_b, consumer,
    (1, 1, 1),
    Route(producer_b => consumer, :value),
)
```

Without `Unique`, repeated equal immutable values or repeated type-based entries
can be treated as the same logical identity.

## Matching Rules

For process entities (`ProcessAlgorithm`/`ProcessState`), the current matching
rules are:

- an immutable instance that Julia can store directly in a type parameter matches by value,
- a mutable or otherwise non-direct instance matches by object identity,
- a type matches by that type.

So `Fib()` and `Fib` are different identities.

## Why Instance Lookup Can Be Surprising

The practical rule is: reuse the same reference you inserted.

Fresh values can be surprising:

- a fresh immutable value can match an equal inserted immutable value,
- a fresh mutable value is a different object and normally does not match the inserted one,
- a type such as `Fib` targets the type-based entry, not an instance entry like `Fib()`.

## `Unique`

`Unique(x)` wraps `x` in `IdentifiableAlgo` with a UUID identity.

That gives a guaranteed separate registry identity and thus separate subcontext key, even when:

- two wrapped values are otherwise equal,
- they were added by the same type,
- or they are hard to distinguish by normal Julia equality.

## Recommended Patterns

- One logical instance per type: plain type or instance is fine.
- Multiple logical instances of same algorithm: use `Unique(...)` and keep references.
- Inputs/routes/shares for those distinct instances: reference the same `Unique` values you inserted into composition.
