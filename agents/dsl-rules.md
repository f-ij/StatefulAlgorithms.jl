# DSL rules

Decided by the owner, 2026-10-13.

This file is for agents and contributors: when unsure about DSL semantics, these rules win over older docs/notes.

The legacy macros (`@CompositeAlgorithm_legacy`, `@Routine_legacy`, `@StepAlgorithm_legacy`, rules `LegacyDSL`,
`src/Legacy/`) keep their old behaviour; the rules below are those of `@CompositeAlgorithm`, `@Routine` and
`@StepAlgorithm` (rules `CurrentDSL`).

## 1. A step's return is a normal Julia return value

A NamedTuple return is one value. The block may destructure it as any NamedTuple: by name, or positionally. A return
never writes state.

```julia
@StepAlgorithm function Pair(@managed(count = 0))
    @update count += 1
    return (; E = 1.0 * count, M = -1.0 * count)   # one value; writes nothing
end

@CompositeAlgorithm begin
    (; E, M) = Pair()    # by name
    e, m = Pair()        # positionally
end
```

## 2. `x = f()` captures f's return into the block value `x`

It never names a field of f's state, also when f's state has a field `x`.

```julia
@StepAlgorithm function Counter(@managed(count = 0))
    @update count += 1
    return 10 * count
end

@CompositeAlgorithm begin
    count = Counter()    # `count` is 10, 20, ...: Counter's return, not its state field `count`
end
```

## 3. State is written only through `@update` inside `@StepAlgorithm`

`@update` exists only there.

```julia
@StepAlgorithm function AddOne!(val)
    @update val = val + 1   # writes back to whatever the block passed as `val`
end
```

## 4. State is read in the block with the DSL names for a state field

`alias.field`, `y = alias.y`, `@state(X).f` and `(; f) = @state(X)` name a state field; they are lowered to wiring.

```julia
@CompositeAlgorithm begin
    @alias c = Counter()
    c()
    Report(c.count)                 # field of an alias
    Report(@state(Counter).count)   # inline
    (; count) = @state(Counter)     # `count` names the field from here on
end
```

## 5. Hand-written `init` / `step!` are deprecated

Define algorithms with `@StepAlgorithm`: `@managed(...)` state, `@update`, `return`. Do not define
`StatefulAlgorithms.init(::Algo, context)` / `StatefulAlgorithms.step!(::Algo, context)` methods by hand.

```julia
# Deprecated:
#   struct Counter <: ProcessAlgorithm end
#   StatefulAlgorithms.init(::Counter, context) = (; count = 0)
#   StatefulAlgorithms.step!(::Counter, context) = (; count = context.count + 1)
@StepAlgorithm function Counter(@managed(count = 0))
    @update count += 1
end
```

## 6. `x = @repeat spec Algo()` is a build error

The return of a repeated statement is not a value of the block. Repeat without `x =`, or capture inside a repeated
block. Plain `@repeat spec Algo()` stays valid.

```julia
@Routine begin
    # x = @repeat 3 Counter()      # error when the block is built
    @repeat 3 Counter()            # fine
    local x
    @repeat 3 begin
        x = Counter()              # x is the last repeat's return
    end
end
```

## 7. A nested plan has no return value

`x = nested()` with `nested` a plan (`@CompositeAlgorithm` / `@Routine` block), and `x = @repeat n begin … end`, are
build errors. Declare `local x` before the plan and assign `x` inside it.

```julia
@CompositeAlgorithm begin
    # result = @repeat 2 begin … end   # error when the block is built
    local result
    @repeat 2 begin
        result = f()
    end
    g(result)
end
```
