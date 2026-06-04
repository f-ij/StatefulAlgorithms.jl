# [Copying Processes](@id copying_processes_user)

```@meta
CurrentModule = StatefulAlgorithms
```

This page documents the process-copy helpers.

A process copy is rebuilt from saved construction data, not by copying the live
context directly. This matters when a context was initialized from external
storage, buffers, or data views.

If you want to run many independent jobs through reusable processes on Julia
threads, see [Threaded Process Managers](@ref threaded_process_managers_user).

## Why Copy Instead of `deepcopy`

`Process` contexts are often built from `Init(...)` values that point at external storage,
buffers, or data views. A raw `deepcopy` of the live context can therefore copy the wrong
thing or preserve sharing that should be rebuilt per process.

The copying helpers work from the initialized loop algorithm and the normal
lifecycle init pipeline instead:

- copy the stored loop algorithm recipe,
- replace selected inputs and overrides,
- initialize a fresh context for each copy.

The saved recipe is the initialized loop algorithm: it stores the resolved
algorithm, persistent context, and replayable `Init`/`Override` specs.

## Copy APIs

```@docs
StatefulAlgorithms.copyinputs
StatefulAlgorithms.copyoverrides
StatefulAlgorithms.copyprocess
```

## Typical Copy Pattern

```julia
template = Process(
    MyAlgo,
    Init(MyAlgo; start = 0, buffer = Int[]),
    Override(MyAlgo; delta = 2);
    repeats = 10,
)

p = copyprocess(
    template,
    Init(MyAlgo; start = 100, buffer = Int[]),
)

run(p)
wait(p)
close(p)
```

If the context needs custom rebuilding logic, provide a fully prepared
`context = ...` directly.
