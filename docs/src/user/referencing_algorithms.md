# [Referencing Algorithms](@id referencing_algorithms_user)

Use this page whenever you need to point to a specific algorithm in:

- `Route(...)`
- `Share(...)`
- `Input(...)`
- `Override(...)`

## One Rule

Reference algorithms the same way you inserted them into the composition.

- Added by type -> reference by that type.
- Added by saved instance variable -> reference by that same variable.
- Added by `Unique(...)` -> reference by that same saved unique variable.

## Pattern 1: Added by Type

```julia
struct Producer <: ProcessAlgorithm end
struct Consumer <: ProcessAlgorithm end

algo = CompositeAlgorithm(
    Producer, Consumer,
    (1, 1),
    Route(Producer => Consumer, :value),
)
```

Use `Producer` and `Consumer` again when targeting these algorithms.

## Pattern 2: Added by Instance

```julia
producer = Producer()
consumer = Consumer()

algo = CompositeAlgorithm(
    producer, consumer,
    (1, 1),
    Route(producer => consumer, :value),
)
```

Use `producer` and `consumer` again, not fresh `Producer()` calls.

## Pattern 3: Added with `Unique`

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

`producer_b` is a distinct identity. Keep that variable and reuse it anywhere you need to target that exact algorithm.

## Common Mistake

Do not create a new object in `Route`/`Share`/`Input`/`Override` unless that exact object was inserted in the composition.

Some immutable objects can match by equal value, but relying on that makes code
harder to read. Reusing the original reference is the clearest rule.
