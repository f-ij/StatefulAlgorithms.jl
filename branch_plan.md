# immutable_nongen_fix branch plan

## Goal

Refactor loop execution so `ProcessContext` is literal persistent system state:
named subcontexts plus a registry. Runtime inputs, loop handles, DSL temporaries,
and transient algorithm returns live in a separate hot runtime context that is
owned by the loop kernel and never returned or stored.

## Current implementation direction

- `ProcessContext{D,R}` stores only `subcontexts::D` and `reg::R`.
- Stored/resolved contexts carry `reg <: AbstractRegistry`.
- Hot loop contexts use the same type with `reg === nothing`.
- `SubContextView` holds both the hot state context and hot runtime context.
- Internal `_step!` methods thread `(context, runtimecontext)` through composite
  and routine children.
- Unknown step return fields are merged into owner-scoped runtime subcontexts,
  not widened into persistent state.
- The actual loop body is wrapped in a `@noinline` kernel. The kernel calls a
  `@noinline finalizer!`, which receives both contexts, runs cleanup/finalstep,
  and returns only persistent state plus the public return value.

## Deferred optimization

Add compile-time demand analysis over wiring, observers, and finalstep access.
If no downstream consumer asks for a returned variable, merge should ignore that
field entirely: no persistent write and no runtime write.

This is intentionally documented but not implemented in the first refactor.
