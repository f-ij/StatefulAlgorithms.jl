# Accessors Context Rebuild Freeze Notes

Date: 2026-05-30

## Short Version

The observed "freeze" was not a loop-control deadlock and not user dynamics
blocking. The strongest evidence points to pathological first-call compilation
in LLVM/codegen caused by the Accessors-based immutable context rebuild path.

`Accessors.@set` is not doing secret runtime work in the hot loop. The problem
is that, for our generated process step code and very large concrete context
types, the generic reconstruction machinery can produce a much harder compiler
problem than the equivalent package-specific constructor rebuild.

The current source avoids that path. Context updates stay immutable, but use
small StatefulAlgorithms-specific rebuild helpers instead:

- `withdata(sc, data)` rebuilds `SubContext`.
- `withruntime(pc, runtime)` rebuilds `ProcessContext` with a new `_runtime`.
- `withsubcontexts(pc, subcontexts)` rebuilds `ProcessContext` with new
  subcontexts.
- `replace_namedtuple_field(nt, Val(name), value)` rebuilds exactly one
  existing `NamedTuple` field.

## What Was Observed

The problematic InteractiveIsing probe was:

```text
ext/IsingLearning/experiments/MNIST/784-120-40-baseline/diagnostics/runs/20260530_182019_backend_update_contrastive_learning_retest/local_langevin_learning_vs_process.jl
```

The reported regression started at commit:

```text
387e206d9a743ad678e119ab1b5ecb0fd5093e56
```

That commit was focused on context representation/rebuild changes:

- `SubContext` became immutable.
- `SubContext` changed from `SubContext{Name,T}` to `SubContext{T}` with
  `name::Symbol`.
- Same-type context writes switched from in-place `setfield!` to immutable
  rebuilds using Accessors `@set`.
- Top-level `ProcessContext` field replacements also used Accessors `@set`.

The run appeared to hang before normal process ticks or loop indexes advanced.
More precise markers showed this was before the user DSL body did meaningful
work. That made user dynamics, projection, copy-out, and routine loop-control
less likely as causes.

When a stuck Julia process was interrupted with `kill -QUIT`, the stack was in
LLVM optimization/compilation, especially LLVM `InstCombine`, while compiling
`runprocessinline!`. That is the key observation: the process was spending time
compiling generated code, not waiting on a runtime lock or spinning in the user
algorithm.

## What Was Ruled Out

Several smaller versions of the free-phase shape completed:

- A plain `dynamics()` child completed.
- `@repeat 1 dynamics()` completed.
- Projection alone completed.
- Copy-out alone completed.
- Reset plus projection plus repeat completed, although first compilation was
  already expensive.

This ruled out "LocalLangevin as a child" and "the repeat syntax by itself" as
the explanation.

The failure shape was the full generated routine/context combination: generated
process entry, repeated child stepping, projected field logic, copy-out, and the
large concrete immutable context rebuild types all compiled together.

## Accessors Experiment Results

The vendored `InteractiveIsing.jl/deps/StatefulAlgorithms` copy was patched locally to
compare context rebuild strategies against the same probe.

Results:

```text
Accessors @set immutable rebuild:
    Pathological compile/codegen latency. The run looked frozen.

Manual immutable constructor rebuild, SubContext{T} with name::Symbol:
    Completed, but first run still took about 135 seconds.

Manual immutable constructor rebuild, SubContext{Name,T}:
    Completed, but first run still took about 120 seconds.

Mutable SubContext{Name,T} with same-type setfield!:
    Completed, runprocessinline region about 14.6 seconds.

Mutable SubContext{T} with name::Symbol and same-type setfield!:
    Completed, runprocessinline region about 14.7 seconds.
```

Interpretation:

- Accessors was the worst compile path.
- Manual immutable rebuild avoided the most pathological behavior, but large
  immutable rebuild IR was still much more expensive to compile than mutation.
- Putting the subcontext name in the type was not the decisive variable for the
  freeze.
- The decisive variable for the freeze was the Accessors/generic immutable
  rebuild path inside large generated process code.

## Why Accessors Can Be Worse Here

For a simple local expression, `@set x.a = b` feels equivalent to manually
constructing a new object. In this codebase the surrounding shape is not simple:

- `ProcessContext` contains a large `NamedTuple` of subcontexts.
- Each `SubContext` contains a typed `NamedTuple` payload.
- Generated step code already specializes on process structure, child order,
  routes, aliases, state, and return stability.
- A single large routine can create very large concrete IR before the first
  process tick.

Accessors must solve the general "set this nested property path immutably"
problem. That means it goes through generic property-lens/reconstruction
machinery and ConstructionBase-style reconstruction hooks. Even if all of that
is resolved at compile time, the compiler still has to infer, inline, optimize,
and codegen the expanded generic machinery in the middle of our already-large
generated step method.

The package-specific replacement does less:

```julia
new_subcontext = withdata(subcontext, new_data)
new_subcontexts = replace_namedtuple_field(old_subcontexts, Val(name), new_subcontext)
return withsubcontexts(pc, new_subcontexts)
```

That is not more semantically clever than Accessors. It is intentionally less
general, so the compiler sees a smaller and more direct reconstruction problem.

## Why We Still Want Immutability

The mutable subcontext experiment was useful because it proved the compile
problem was tied to immutable rebuild/codegen shape. It is not the desired final
direction for tiny scalar workloads.

Mutable `SubContext` puts each subcontext behind a heap object. Even when the
hot loop reports zero fresh allocations, the scalar fields are no longer
obviously inline fields inside one immutable aggregate. That can prevent the
best scalar replacement/SROA behavior for small contexts with only a few scalar
fields.

So the current goal is:

- keep `ProcessContext` immutable;
- keep `SubContext` immutable;
- avoid Accessors in context hot paths;
- use manual, package-specific rebuilds that are small enough for the compiler;
- continue measuring whether LLVM can scalar-replace the tiny cases.

## Current Active Implementation

The active context rebuild path is in:

```text
src/Context/SubContext.jl
src/Context/ProcessContexts.jl
src/Functions.jl
```

The important helpers are:

```julia
withdata(sc, data)
withruntime(pc, runtime)
withsubcontexts(pc, subcontexts)
replace_namedtuple_field(nt, Val(name), value)
```

The old Accessors and mutable `setfield!` alternatives are left as comments near
the relevant code paths where useful for comparison.

`src/StatefulAlgorithms.jl` no longer imports `Accessors.@set` for these context rebuilds,
and Accessors is no longer a direct dependency in `Project.toml` or
`Manifest.toml`.

## Remaining Uncertainty

This is not yet proof that manual immutable rebuilds recover the best possible
SROA behavior in all workloads. It only says:

- Accessors was a bad compile path for the InteractiveIsing generated routine.
- Manual immutable rebuilds are simpler and avoid the worst Accessors freeze.
- Mutable subcontexts compile much faster but have an unacceptable performance
  model for tiny scalar contexts.

The next thing to verify is whether the package-specific immutable rebuild path
keeps the route-heavy benchmark near parity while improving or at least not
destroying the tiny scalar replacement probes.
