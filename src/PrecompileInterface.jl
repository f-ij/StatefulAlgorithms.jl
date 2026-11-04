#=
What a process compiles when it is built: `precompile_interface(x)`, one hook that every process type extends here, in
this file, so all of it is in one place. Each method is one block of plain `precompile` calls for the calls a user
makes on that type that should not compile when first made, written however suits the type. On this branch no type
extends it yet (the precompiles come with a later branch).

Not the package's precompile workload (src/Precompile.jl): that runs once, while the package image is written.
=#

"""Whether Julia is building the package image (precompilation) right now."""
_is_generating_package_output() = ccall(:jl_generating_output, Cint, ()) != 0

"""
    precompile_interface(x) -> nothing

Hook: compiles, when `x` is built, the calls on it a user makes that should not compile when first made. The default
compiles nothing. Called by the `Process` and `InlineProcess` constructors; a process type extends it in this file.
"""
precompile_interface(x::X) where {X} = nothing

# How a method is written: `precompile` each call with the tuple of its argument types, which are all known from the
# built process. For a `Process` run, the function its task calls:
#     precompile(_run_loop_and_store!, (P, typeof(loop), InteractiveSession{C, LT}, F, LC, LT, Resuming{false}))
# with `P` the process type, `F` its plan, `LT` its lifetime, `C` its cursor type (`P.parameters[2]`) and `LC` the
# `LoopContext` type `prepare_for_loop` builds for a run without inputs. Mark `_run_loop_and_store!` `@noinline`, so the
# task's closure calls this compiled method instead of compiling the loop again inline. Whether calls are spawned on
# tasks to run in parallel is decided per process type, inside its one method; no helper functions or job types.
