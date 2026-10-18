#=
Precompile workload: what a user's first `@StepAlgorithm`, DSL block, `Process`, `run` and `show` would otherwise
compile.

Only code that does not depend on the user's own types can be kept: the macro expanders, the parts of preparing a
plan that walk it untyped (resolve, scopes, wiring), `Process`/lifetime/manager machinery, printing, and the Base
methods those call. A plan's loop, its context and its routes have the user's types and names in their types, so
they are compiled again for every plan whatever runs here.

Two rules follow from how PrecompileTools keeps code:
1. Base methods (on Base types) are kept only if they are compiled while a `@compile_workload` runs. A macro written
   literally in this file is expanded when the file is lowered, before any workload runs, so the Base code its
   expansion uses is not kept. The macro sections below call `macroexpand` at run time for that reason.
2. Code specialised on the workload's own algorithm types is kept but only helps a user who runs those types; it is
   here for the generic code it calls.

Sections run from the most common first use (defining algorithms, building a DSL block, running a Process, printing
it) to rarer paths. Their comments give what they save on a user's first calls, measured on perf/precompile-workload
(2026-10-18, Julia 1.13.1, M5 Pro under other jobs' load): compile seconds (`Base.cumulative_compile_time_ns`; wall
time is within 2% of it), min of 3 fresh processes, in three scenarios that use only user-defined types:
  - user: four `@StepAlgorithm`s, a DSL block with `@state`/`@alias`/`local`/`@interval`, resolve, run, `show`, a
    rebuild with another interval, `@Routine` with `@repeat`, constructors, `Input`/`Override`, `Until`, InlineProcess.
  - manuscript: InteractiveIsing P1_script/V2.5 routes/00_job_helpers.jl in SA terms: struct algorithms with `init`/
    `step!`, loggers, `@alias`/`@every`/`@transform`/`@context`/`@repeat`/`@redirect`, `Init` by name and instance,
    run + fetch, an on-demand threaded ProcessManager.
  - learning: IsingLearning LearningProcessTools.jl: `@config` algorithms, bare `@state` lines, `@context c = @repeat n
    block()` with six `@bind`s, plain calls on fields, `Init(:_state_1; ...)`, the reset!/run/wait loop.

Totals (compile s, first calls only)       precompile   image    user   manuscript   learning   `using`
  no workload                                 2.7 s     10 MB    6.76      5.38        7.33      0.10 s
  workload before this branch                 9.9 s     40 MB    3.03      2.84        4.18      0.18 s
  this file                                  13.1 s     57 MB    2.40      2.54        3.74      0.24 s

InteractiveIsing includes this package as a submodule, so this workload runs in its precompile too. On the pulse job of
P1_script/V2.5 (6×6×2 graph, Haoran's routes with `@replace` → `@redirect`) it saves 0.06 s while the helpers are
included and 0.14 s of the job's 10.5 s first build: the rest is Makie (≈6 s) and plan-specific code (≈1.3 s).

Each section lists two savings. "Unique": the time that goes away only with this section (all sections minus this one,
against all sections; noise about ±0.05 s per scenario, except ±0.06 s on learning's `@bind` block alone). "Alone":
this section with nothing else but the definitions below, against those definitions alone; most of that overlaps with
other sections (noise about ±0.15 s, the runs were minutes apart). Costs are for the unique part.

What no section here can remove: a plan's own loop, context and routes (the user's types and names are in their types),
`show` of a Process (≈0.065 s per new Process type, specialised on it), and `@bind`, which compiles `Base.grow_to!` for
every route tuple (≈0.25 s per `@bind`, 2.1 s for learning's six; a plain loop in `_composite_dsl_rebind_wires` brings
that to 0.74 s, see TODO.md).
=#

################################
### Workload algorithm types ###
################################
# These definitions alone (written literally, so expanded while this file is lowered) save the first `@StepAlgorithm`
# ≈0.75 s (user ≈0.73 s, learning's `@config` algorithm ≈0.82 s): the macro's own code is kept, its Base calls are not
# (those are what the macro section below adds). Cost: +0.8 s precompile, +2.8 MB.

mutable struct _ProcessPrecompileFakeWorker
    idx::Int
    value::Int
    done::Bool
end

# `value` and `total` start from the init context when given there (`Input`), else 0.
@StepAlgorithm function _ProcessPrecompileCounter(@managed(value = get(context, :value, 0), total = get(context, :total, 0)))
    @update value += 1
    @update total += value
end

function cleanup(::_ProcessPrecompileCounter, context)
    return (; total = context.total)
end

# `offset` when routed in.
@StepAlgorithm function _ProcessPrecompileScaler(@managed(factor = get(context, :factor, 2), scaled = get(context, :scaled, 0)); offset = 0)
    @update scaled += factor + offset
end

@StepAlgorithm function _ProcessPrecompileSink(value, @managed(seen = get(context, :seen, 0.0)))
    @update seen += value
end

@StepAlgorithm function _ProcessPrecompileNoop()
    return
end
cleanup(::_ProcessPrecompileNoop, context) = (;)

@StepAlgorithm function _ProcessPrecompileVectorPush(@managed(values = (v = Float64[]; processsizehint!(v, context); v), source = get(context, :source, 0.0)))
    push!(values, source)
    return
end

@StepAlgorithm function _ProcessPrecompileSharedReader(source, @managed(total = 0.0))
    @update total += source
end

@StepAlgorithm function _ProcessPrecompileSource(seed)
    produced = seed * 2.0
    passthrough = seed + 1.0
    return (; produced, passthrough)
end

@StepAlgorithm function _ProcessPrecompileManaged(
    x,
    @managed(total = start);
    gain = 1.0,
    @init((; start = 0.0))
)
    @update total = total + x * gain
    return total
end

@StepAlgorithm @config offset::Float64 = 1.0 begin
    function _ProcessPrecompileConfigured(
        x;
        gain = 1.0,
        @init((;))
    )
        y = x * gain + offset
        return (; y, offset)
    end
end

# Hand-written algorithms: a struct with `init` and `step!` methods, the way InteractiveIsing and its manuscript
# scripts write dynamics and loggers.
struct _ProcessPrecompileDynamics <: ProcessAlgorithm end
function init(::_ProcessPrecompileDynamics, context)
    model = context.model
    return (; model, hamiltonian = (; J = 1.0, h = Ref(0.0)), T = 1.0, M = Ref(sum(model)))
end
function step!(::_ProcessPrecompileDynamics, context::C) where {C}
    (; model, hamiltonian) = context
    i = mod1(length(model) + 1, length(model))
    delta = 2.0 * model[i] * (hamiltonian.J + hamiltonian.h[])
    model[i] = -model[i]
    return (; proposal = (; delta, i))
end

struct _ProcessPrecompileLogger{Name} <: ProcessAlgorithm end
function init(::_ProcessPrecompileLogger, context)
    values = Float64[]
    processsizehint!(values, context)
    return (; values)
end
function step!(::_ProcessPrecompileLogger, context::C) where {C}
    (; values, value) = context
    push!(values, value)
    return (;)
end

struct _ProcessPrecompileIntegrator <: ProcessAlgorithm end
init(::_ProcessPrecompileIntegrator, context) = (; total = Ref(Float64(get(context, :initialvalue, 0.0))), log = Float64[])
function step!(::_ProcessPrecompileIntegrator, context::C) where {C}
    context.total[] += context.value
    push!(context.log, context.total[])
    return (;)
end

struct _ProcessPrecompileProtocol <: ProcessAlgorithm end
init(::_ProcessPrecompileProtocol, context) = (; t = Ref(0))
function step!(::_ProcessPrecompileProtocol, context::C) where {C}
    context.t[] += 1
    context.hamiltonian.h[] = 0.1 * context.t[]
    return (;)
end

_process_precompile_add(x, y; bias = 0.0) = x + y + bias
_process_precompile_scale(x; scale = 1.0) = x * scale
_process_precompile_delta(proposal) = proposal.delta
_process_precompile_field(hamiltonian) = hamiltonian.h[]
_process_precompile_mean(model) = sum(model) / length(model)

#===================================================================================================================
Section: macro expansion of @StepAlgorithm. The first `@StepAlgorithm` a user writes.
Unique: first `@StepAlgorithm` with `@managed` Int defaults −0.04 s (user), an `@StepAlgorithm @config` block
−0.14 s (learning). Alone: the same (−0.04, −0.12 s). Cost: +0.2 s precompile, +0.8 MB.
===================================================================================================================#
#== section: macro_stepalgorithm ==#
@compile_workload begin
    # Each form at run time, so the Base code the expanders use is kept (see rule 1 at the top). Expanding is
    # enough: the expansion is not evaluated.
    macroexpand(@__MODULE__, :(@StepAlgorithm function _PcA(@managed(value = 0, total = 0))
        @update value += 1
        @update total += value
    end))
    macroexpand(@__MODULE__, :(@StepAlgorithm function _PcB(x, @managed(scaled = 0.0); gain = 1.0)
        @update scaled += x * gain
    end))
    macroexpand(@__MODULE__, :(@StepAlgorithm function _PcC(x, @managed(values = Float64[], n::Int = 0))
        push!(values, x)
        return
    end))
    macroexpand(@__MODULE__, :(@StepAlgorithm function _PcD(seed)
        return (; produced = 2.0 * seed, passthrough = seed + 1.0)
    end))
    macroexpand(@__MODULE__, :(@StepAlgorithm function _PcE(@managed(total = start, buffer = zeros(n)); @init((; start = 0.0, n = 3)))
        @update total += sum(buffer)
    end))
    macroexpand(@__MODULE__, :(@StepAlgorithm @inline function _PcF(@managed(model, rng = get(context, :rng, nothing), T = 1.0f0); @init((; seed = nothing))) <: ProcessAlgorithm
        return (; energy = T * sum(model))
    end))
    macroexpand(@__MODULE__, :(@StepAlgorithm @config gain::Float32 = 5.0f0 begin
        @config n_steps::Int = 1
        function _PcG(graph, @managed(step_idx::Int = 0), @managed(current::Float32 = gain))
            @update step_idx += 1
            return (; level = 2current)
        end
    end))
    macroexpand(@__MODULE__, :(@StepAlgorithm function _PcH(x::Vector{Float64}, scale::Base.RefValue{Float64})
        x .*= scale[]
        return nothing
    end))
end
#== end: macro_stepalgorithm ==#

#===================================================================================================================
Section: macro expansion of @CompositeAlgorithm / @Routine / @state. The first DSL block.
Unique: first `@CompositeAlgorithm` −0.20 s (user), first `@Routine` of bare `@state` lines −0.18 s (learning),
manuscript −0.03 s. Alone: first DSL block −1.09 s (user), −0.86 s (manuscript), −0.78 s (learning), most of it
shared with the sections that build DSL blocks. Cost: +0.0 s precompile, +0.5 MB (alone +1.0 s, +3.0 MB).
===================================================================================================================#
#== section: macro_dsl ==#
@compile_workload begin
    # The statements of the DSL, in the forms used by this package's examples, InteractiveIsing and its manuscript
    # scripts (P1_script/V2.5/routes) and IsingLearning.
    macroexpand(@__MODULE__, :(@CompositeAlgorithm begin
        @state seed = 1.0
        @alias src = _ProcessPrecompileSource
        local doubled
        (; produced, passthrough) = src(seed)
        doubled = @interval 2 _process_precompile_scale(produced; scale = 2.0)
        @interval 2 _ProcessPrecompileSink(value = doubled)
        _ProcessPrecompileCounter()
    end))
    macroexpand(@__MODULE__, :(@CompositeAlgorithm begin
        @alias dynamics = _ProcessPrecompileDynamics
        (; proposal) = dynamics()
        @every 1 _ProcessPrecompileIntegrator()(value = @transform(_process_precompile_delta, proposal))
        @every 4 _ProcessPrecompileLogger{:field}()(value = @transform(_process_precompile_field, dynamics.hamiltonian))
        @every 4 _ProcessPrecompileLogger{:top}()(value = @transform(x -> sum(x), dynamics.model))
    end))
    macroexpand(@__MODULE__, :(@CompositeAlgorithm begin
        @alias dynamics = _ProcessPrecompileDynamics
        @alias other = _ProcessPrecompileDynamics
        @redirect dynamics.T => other.T
        dynamics()
        @every 4 other()
    end))
    macroexpand(@__MODULE__, :(@CompositeAlgorithm begin
        @context monte_carlo = inner()
        @every 4 _ProcessPrecompileProtocol()(hamiltonian = monte_carlo.dynamics.hamiltonian, M = monte_carlo.dynamics.M)
    end))
    macroexpand(@__MODULE__, :(@Routine begin
        @repeat 8 field_step()
        @repeat 4 relax_step()
    end))
    macroexpand(@__MODULE__, :(@Routine begin
        @state seed = 2.0
        local produced
        @repeat 3 begin
            (; produced) = _ProcessPrecompileSource(seed)
        end
        _ProcessPrecompileVectorPush(source = produced)
    end))
    macroexpand(@__MODULE__, :(@Routine begin
        @state x
        @state buffers
        @state rng
        _process_precompile_add(x, buffers)
        @context phase_ctx = @repeat 2 phase()
        @bind x => phase_ctx.x
        @bind buffers => phase_ctx.buffers
    end))
    macroexpand(@__MODULE__, :(@CompositeAlgorithm begin
        @state precompile_named_state begin
            seed = 1.0
            offset = 2.0
        end
        value = +(seed, offset)
        _ProcessPrecompileSink(value = value)
    end))
    macroexpand(@__MODULE__, :(@state begin
        seed = 2.0
        bias
    end))
end
#== end: macro_dsl ==#

#===================================================================================================================
Section: one algorithm in a Process: construct, run, wait, fetch, close; init/step! by hand.
Unique: within noise (≤0.04 s per scenario): the sections below run Processes too. Alone: −1.1 to −1.3 s per scenario:
first `resolve` −0.55 s, first run −0.4 to −0.5 s, first `Process(...)` −0.2 s (manuscript's −0.72 s). This is the
shared Process/resolve/context machinery; keep at least one section that runs a Process. Cost: +0.0 s, +0.7 MB
(alone +1.5 s, +6.2 MB).
===================================================================================================================#
#== section: process_basics ==#
@compile_workload begin
    init(_ProcessPrecompileSource(), (;))
    step!(_ProcessPrecompileSource(), (; seed = 2.0))
    managed_state = init(_ProcessPrecompileManaged(), (; start = 1.0))
    step!(_ProcessPrecompileManaged(), (; x = 2.0, total = managed_state.total, gain = 3.0))
    step!(_ProcessPrecompileManaged(), 2.0; _init = (; start = 1.0), gain = 3.0)

    configured = _ProcessPrecompileConfigured(offset = 2.0)
    init(configured, (;))
    step!(configured, 2.0; gain = 3.0)
    step!(configured, (; x = 2.0, gain = 3.0))

    state_only = @state begin
        seed = 2.0
        bias = 1.0
    end
    init(state_only, (;))

    process = Process(_ProcessPrecompileCounter(); repeats = 2)
    run(process)
    wait(process)
    fetch(process)
    close(process)

    typed_process = Process(_ProcessPrecompileCounter; repeats = 1)
    run(typed_process)
    wait(typed_process)
    context(typed_process)[_ProcessPrecompileCounter].total
    close(typed_process)

    input_process = Process(
        _ProcessPrecompileCounter,
        Input(_ProcessPrecompileCounter, :value => 3),
        Override(_ProcessPrecompileCounter, :total => 5);
        repeats = 1,
    )
    run(input_process)
    wait(input_process)
    close(input_process)

    # The reuse loop of IsingLearning: reset!, run, wait.
    reused = Process(_ProcessPrecompileCounter; repeats = 1)
    run(reused); wait(reused)
    reset!(reused)
    run(reused); wait(reused)
    close(reused)
end
#== end: process_basics ==#

#===================================================================================================================
Section: DSL blocks built, resolved and run: state, alias, plain calls, intervals, locals, routines.
Unique: −0.06 s (user), −0.03 s (manuscript), −0.12 s (learning), spread over many phases of ≤0.04 s. Alone: −2.2 to
−2.7 s (first DSL block −1.0 to −1.2 s, Process, run, resolve), overlapping with scoping_reuse and struct_algorithms.
Cost: +0.8 s precompile, +5.7 MB.
===================================================================================================================#
#== section: dsl_run ==#
@compile_workload begin
    dsl_routine = @Routine begin
        _ProcessPrecompileCounter()
        _ProcessPrecompileScaler()
    end
    dsl_routine_process = Process(dsl_routine; repeats = 1)
    run(dsl_routine_process)
    wait(dsl_routine_process)
    close(dsl_routine_process)

    dsl_composite = @CompositeAlgorithm begin
        _ProcessPrecompileCounter()
        _ProcessPrecompileScaler()
    end
    dsl_composite_process = Process(dsl_composite; repeats = 1)
    run(dsl_composite_process)
    wait(dsl_composite_process)
    close(dsl_composite_process)

    dsl_composite_routed = @CompositeAlgorithm begin
        @state seed = 2.0
        @state bias = 1.0
        @alias src = _ProcessPrecompileSource
        (; produced, passthrough) = src(seed)
        scaled = _process_precompile_scale(produced; scale = 3.0)
        combined = _process_precompile_add(scaled, passthrough; bias = bias)
        _ProcessPrecompileSink(value = combined)
    end
    resolved_dsl_composite_routed = resolve(dsl_composite_routed)
    initcontext(resolved_dsl_composite_routed)
    dsl_routed_process = Process(resolved_dsl_composite_routed; repeats = 2)
    run(dsl_routed_process)
    wait(dsl_routed_process)
    close(dsl_routed_process)

    dsl_interval_composite = @CompositeAlgorithm begin
        @interval 2 _ProcessPrecompileCounter()
        _ProcessPrecompileScaler()
    end
    resolved_dsl_interval_composite = resolve(dsl_interval_composite)
    initcontext(resolved_dsl_interval_composite)

    dsl_routine_with_state = @Routine begin
        @state precompile_routine_state begin
            seed = 1.0
        end
        _ProcessPrecompileSource(seed)
        _ProcessPrecompileSink(value = seed)
    end
    resolved_dsl_routine_with_state = resolve(dsl_routine_with_state)
    initcontext(resolved_dsl_routine_with_state)
    dsl_routine_state_process = Process(resolved_dsl_routine_with_state; repeats = 1)
    run(dsl_routine_state_process)
    wait(dsl_routine_state_process)
    close(dsl_routine_state_process)

    large_dsl_funcwrapper_routine = @Routine begin
        @state seed = 1.0
        @state bias = 0.25
        v1 = _process_precompile_scale(seed; scale = 1.01)
        v2 = _process_precompile_add(v1, bias; bias = 0.02)
        v3 = _process_precompile_scale(v2; scale = 1.03)
        v4 = _process_precompile_add(v3, v1; bias = 0.04)
        v5 = _process_precompile_scale(v4; scale = 1.05)
        v6 = _process_precompile_add(@transform(x -> x + 0.11, v5), bias; bias = 0.11)
    end
    resolved_large_dsl_funcwrapper_routine = resolve(large_dsl_funcwrapper_routine)
    initcontext(resolved_large_dsl_funcwrapper_routine)
    large_dsl_process = Process(resolved_large_dsl_funcwrapper_routine; repeats = 1)
    run(large_dsl_process)
    wait(large_dsl_process)
    close(large_dsl_process)
end
#== end: dsl_run ==#

#===================================================================================================================
Section: scoping and plan reuse. Locals typed at their first write (`local x`, assigned on an interval), a repeated
block, nested `@context`/`@bind` scopes, and the same layout built again with other values and other intervals.
Unique: −0.22 s (user: first run −0.09 s, `@Routine` with `@repeat` −0.05 s, DSL block −0.03 s, routine run −0.03 s),
−0.05 s (manuscript), −0.11 s (learning, part of it in the `@bind` block's noise). The plan-reuse part (the second
build of the loop) shows up as the user's rebuild phase staying at ≈0.25 s in every variant: that is per-plan code.
Alone: −2.2 to −3.1 s. Cost: +1.4 s precompile, +8.0 MB (the largest).
===================================================================================================================#
#== section: scoping_reuse ==#
@compile_workload begin
    for n in (2, 3)    # the same layout twice, with another interval: the second build reuses the first's code
        scoped = @CompositeAlgorithm begin
            @state seed = 1.0
            @alias src = _ProcessPrecompileSource
            local doubled
            (; produced, passthrough) = src(seed)
            doubled = @interval n _process_precompile_scale(produced; scale = 2.0)
            @interval n _ProcessPrecompileSink(value = doubled)
            _ProcessPrecompileCounter()
        end
        scoped_process = Process(resolve(scoped); repeats = 2n)
        run(scoped_process)
        wait(scoped_process)
        close(scoped_process)
    end

    repeated = @Routine begin
        @state seed = 2.0
        local produced
        @repeat 3 begin
            (; produced) = _ProcessPrecompileSource(seed)
        end
        _ProcessPrecompileVectorPush(source = produced)
    end
    repeated_process = Process(resolve(repeated); repeats = 1)
    run(repeated_process)
    wait(repeated_process)
    close(repeated_process)

    # Two different blocks: binding two `@context`s of the same block fails on this branch ("The block has no
    # `@state`"), see TODO.md.
    adder = @Routine begin
        @state total
        total = _process_precompile_add(total, 1.0)
    end
    scaler = @Routine begin
        @state total
        total = _process_precompile_scale(total; scale = 1.5)
    end
    bound = @CompositeAlgorithm begin
        @state total = 0.0
        @context added = adder()
        @context scaled = scaler()
        @bind total => added.total
        @bind total => scaled.total
    end
    bound_process = Process(resolve(bound); repeats = 2)
    run(bound_process)
    wait(bound_process)
    close(bound_process)

    # Unique ids: the same algorithm twice, kept apart.
    uniques = CompositeAlgorithm(Unique(_ProcessPrecompileCounter()), Unique(_ProcessPrecompileCounter()), (1, 2))
    resolve(uniques)
end
#== end: scoping_reuse ==#

#===================================================================================================================
Section: hand-written struct algorithms in DSL blocks, the InteractiveIsing manuscript shape: @alias, @every,
@transform, @context, @repeat, `Init` by name and by instance, run, fetch, `context[algo].field`.
Unique: −0.13 s (manuscript, ≈0.02 s in each of its phases: blocks, Process, run, manager), −0.05 s (user),
−0.1 s (learning, mostly noise). Alone: −2.1 to −2.7 s. Cost: +0.6 s precompile, +4.8 MB.
===================================================================================================================#
#== section: struct_algorithms ==#
@compile_workload begin
    dynamics = _ProcessPrecompileDynamics()
    polarization = _ProcessPrecompileIntegrator()
    field_logger = _ProcessPrecompileLogger{:field}()
    top_logger = _ProcessPrecompileLogger{:top}()
    monte_carlo_block = @CompositeAlgorithm begin
        @alias dynamics = dynamics
        (; proposal) = dynamics()
        @every 1 polarization(value = @transform(_process_precompile_delta, proposal))
        @every 4 field_logger(value = @transform(_process_precompile_field, dynamics.hamiltonian))
        @every 4 top_logger(value = @transform(_process_precompile_mean, dynamics.model))
    end
    field_step = @CompositeAlgorithm begin
        @context monte_carlo = monte_carlo_block()
        @every 4 _ProcessPrecompileProtocol()(hamiltonian = monte_carlo.dynamics.hamiltonian)
    end
    relax_step = @CompositeAlgorithm begin
        @context monte_carlo = monte_carlo_block()
    end
    protocol = @Routine begin
        @repeat 8 field_step()
        @repeat 4 relax_step()
    end
    # `Init(dynamics; ...)` by instance. By name (`Init(:dynamics; ...)`, also `Input(:name, ...)` or `haskey(registry,
    # :name)`) the package image fails to load on Julia 1.13.1 (UndefRefError in Compiler/src/reinfer.jl verify_method:
    # a cached CodeInstance without edges), see TODO.md.
    protocol_process = Process(protocol, Init(dynamics; model = ones(8)), Init(polarization, initialvalue = 8.0); repeats = 1)
    run(protocol_process)
    protocol_context = fetch(protocol_process)
    protocol_context[polarization].log
    protocol_context[field_logger].values
    close(protocol_process)
end
#== end: struct_algorithms ==#

#===================================================================================================================
Section: printing. `show` of a Process, a plan (plain and resolved), a context and an InlineProcess, as the REPL
does after each line.
Unique: first `show(io, MIME"text/plain"(), ::Process)` −0.095 s (user), −0.15 s in all for the user scenario; the
rest of that call (≈0.065 s) is compiled for every new Process type. Cost: +0.1 s precompile, +0.6 MB.
===================================================================================================================#
#== section: show ==#
@compile_workload begin
    shown_plan = CompositeAlgorithm(_ProcessPrecompileCounter, _ProcessPrecompileScaler, (1, 2))
    shown_process = Process(shown_plan; repeats = 2)
    run(shown_process)
    wait(shown_process)
    io = IOContext(IOBuffer(), :color => true, :limit => true)
    show(io, MIME"text/plain"(), shown_process)
    show(io, shown_process)
    show(io, MIME"text/plain"(), shown_plan)
    show(io, MIME"text/plain"(), resolve(shown_plan))
    show(io, MIME"text/plain"(), fetch(shown_process))
    show(io, MIME"text/plain"(), Routine(_ProcessPrecompileCounter, _ProcessPrecompileScaler, (2, 1)))
    close(shown_process)

    shown_inline = InlineProcess(_ProcessPrecompileCounter; repeats = 1)
    run(shown_inline)
    show(io, MIME"text/plain"(), shown_inline)
end
#== end: show ==#

#===================================================================================================================
Section: plans built without the DSL: CompositeAlgorithm, Routine, Route, Share, `finalstep`, and the edit
functions.
Unique: −0.05 s per scenario (`CompositeAlgorithm(...) + Route` −0.02 s, InlineProcess −0.01 s; rest in noise). Alone:
−1.1 to −1.4 s, overlapping with process_basics. Cost: +0.5 s precompile, +4.3 MB.
===================================================================================================================#
#== section: constructors ==#
@compile_workload begin
    managed_algo = CompositeAlgorithm(_ProcessPrecompileManaged)
    managed_specs = (
        Input(_ProcessPrecompileManaged, :start => 1.0),
        Override(_ProcessPrecompileManaged, :x => 2.0, :gain => 3.0),
    )
    resolved_managed_algo = resolve(managed_algo)
    resolve_process_inputs_overrides(resolved_managed_algo, managed_specs)
    initialized_managed_algo = StatefulAlgorithms.init(managed_algo, managed_specs...; lifetime = Repeat(1))
    getpersistentcontext(initialized_managed_algo)

    managed_process = Process(managed_algo, managed_specs...; repeats = 1)
    run(managed_process)
    wait(managed_process)
    close(managed_process)

    initialized_managed_process = Process(initialized_managed_algo; repeats = 1)
    run(initialized_managed_process)
    wait(initialized_managed_process)
    close(initialized_managed_process)

    routine = Routine(_ProcessPrecompileCounter, _ProcessPrecompileScaler, (2, 1))
    resolve(routine)
    keys(routine)
    propertynames(routine)
    initcontext(routine)
    routine_process = Process(routine; repeats = 1)
    run(routine_process)
    wait(routine_process)
    close(routine_process)

    composite = CompositeAlgorithm(
        :counter => _ProcessPrecompileCounter,
        :scaler => _ProcessPrecompileScaler,
        (1, 2),
        Route(_ProcessPrecompileCounter => _ProcessPrecompileScaler, :total => :offset),
    )
    resolved_composite = resolve(composite)
    keys(resolved_composite)
    propertynames(resolved_composite)
    initcontext(resolved_composite)
    initcontext(initcontext(resolved_composite), :counter)
    composite_process = Process(composite; repeats = 2)
    run(composite_process)
    wait(composite_process)
    close(composite_process)

    edited_composite = composite |>
        la -> addalgo(la, :extra => _ProcessPrecompileCounter, 1) |>
        la -> changeinterval(la, 1, 2) |>
        la -> changeintervals(la, (1, 1, 1)) |>
        la -> rename(la, :extra => :renamed_extra)
    keys(edited_composite)

    finalized = finalstep(
        CompositeAlgorithm(_ProcessPrecompileCounter, (1,)),
        context -> (; total = context[_ProcessPrecompileCounter].total),
    )
    finalized_process = Process(finalized; repeats = 1)
    run(finalized_process)
    wait(finalized_process)
    fetch(finalized_process)
    close(finalized_process)

    shared = CompositeAlgorithm(
        :writer => _ProcessPrecompileVectorPush,
        :reader => _ProcessPrecompileSharedReader,
        (1, 1),
        Share(_ProcessPrecompileVectorPush, _ProcessPrecompileSharedReader),
    )
    shared_process = Process(
        shared,
        Input(_ProcessPrecompileVectorPush, :source => 1.0);
        repeats = 2,
    )
    run(shared_process)
    wait(shared_process)
    close(shared_process)
end
#== end: constructors ==#

#===================================================================================================================
Section: InlineProcess: run, run_nogen, reset!, threaded and async.
Unique: within noise (≤0.015 s per phase, ≈0.06–0.1 s per scenario spread thin). Alone: −1.0 to −1.3 s, overlapping
with process_basics. Cost: +0.0 s precompile, +0.3 MB.
===================================================================================================================#
#== section: inline ==#
@compile_workload begin
    inline_plain = InlineProcess(_ProcessPrecompileCounter; repeats = 2)
    run(inline_plain)

    inline_process = InlineProcess(
        _ProcessPrecompileManaged,
        Input(_ProcessPrecompileManaged, :start => 1.0),
        Override(_ProcessPrecompileManaged, :x => 1.0, :gain => 2.0);
        repeats = 2,
    )
    run(inline_process)
    run_nogen(inline_process)
    reset!(inline_process)

    composite_inline = InlineProcess(CompositeAlgorithm(_ProcessPrecompileCounter, _ProcessPrecompileScaler, (1, 2)); repeats = 2)
    run(composite_inline)
    run_nogen(composite_inline)
    reset!(composite_inline)

    inline_threaded = InlineProcess(_ProcessPrecompileCounter; repeats = 1, threaded = true)
    inline_threaded_task = run(inline_threaded)
    wait(inline_threaded_task)
    fetch(inline_threaded_task)

    inline_async = InlineProcess(_ProcessPrecompileCounter; repeats = 1, threaded = :async)
    inline_async_task = run(inline_async)
    wait(inline_async_task)
    fetch(inline_async_task)
end
#== end: inline ==#

#===================================================================================================================
Section: lifetimes other than a repeat count: Until, RepeatOrUntil, AtLeast, AtLeastAtMost, Indefinite; makeloop!;
copying a process.
Unique: within noise (0.04–0.08 s per scenario, no phase above 0.015 s). Alone: −1.1 to −1.3 s, overlapping with
process_basics. Cost: +0.3 s precompile, +2.5 MB.
===================================================================================================================#
#== section: lifetimes ==#
@compile_workload begin
    async_process = Process(_ProcessPrecompileScaler; repeats = 1)
    makeloop!(async_process; threaded = false)
    wait(async_process)
    close(async_process)

    until_process = Process(
        _ProcessPrecompileCounter();
        lifetime = RepeatOrUntil(_ -> true, 2, :_captured_returns),
    )
    run(until_process)
    wait(until_process)
    close(until_process)

    until_runtime_process = Process(
        _ProcessPrecompileCounter,
        Input(_ProcessPrecompileCounter, :value => 0);
        lifetime = Until(x -> x >= 2, Var(_ProcessPrecompileCounter, :value)),
    )
    run(until_runtime_process)
    wait(until_runtime_process)
    close(until_runtime_process)

    atleast_process = Process(
        _ProcessPrecompileCounter,
        Input(_ProcessPrecompileCounter, :value => 0);
        lifetime = AtLeast(x -> x >= 2, 1, Var(_ProcessPrecompileCounter, :value)),
    )
    run(atleast_process)
    wait(atleast_process)
    close(atleast_process)

    atleast_atmost_process = Process(
        _ProcessPrecompileCounter,
        Input(_ProcessPrecompileCounter, :value => 0);
        lifetime = AtLeastAtMost(x -> x >= 2, 1, 3, Var(_ProcessPrecompileCounter, :value)),
    )
    run(atleast_atmost_process)
    wait(atleast_atmost_process)
    close(atleast_atmost_process)

    # InteractiveIsing's default: runs until closed.
    indefinite_process = Process(_ProcessPrecompileCounter; lifetime = Indefinite())
    run(indefinite_process)
    close(indefinite_process)

    base_process = Process(
        _ProcessPrecompileScaler,
        Input(_ProcessPrecompileScaler, :factor => 4);
        repeats = 1,
    )
    copyinputs(base_process)
    copyoverrides(base_process)
    copied_process = copyprocess(
        base_process,
        Input(_ProcessPrecompileScaler, :factor => 6);
    )
    run(copied_process)
    wait(copied_process)
    close(copied_process)
    close(base_process)
end
#== end: lifetimes ==#

#===================================================================================================================
Section: ProcessManager: fake workers, Process workers with a shared state, reinitialized workers, and the
on-demand threaded setup of the manuscript scripts (shared/ManagedCaseRunner.jl).
Unique: the first on-demand threaded ProcessManager −0.16 s (manuscript, −0.20 s in all), user −0.06 s. Alone: −1.1 to
−1.4 s, overlapping with process_basics. Cost: +0.5 s precompile, +3.4 MB.
===================================================================================================================#
#== section: manager ==#
@setup_workload begin
    @StepAlgorithm function ProcessManagerPrecompileStep(
        @managed(
            x = Ref(0.0),
            y = Ref(0.0),
            params = Ref((w = 0.0, b = 0.0)),
            grad_w = Ref(0.0),
            grad_b = Ref(0.0),
            loss = Ref(0.0),
            nseen = Ref(0),
        );
        @init((;))
    )
        current = params[]
        prediction = current.w * x[] + current.b
        err = prediction - y[]
        grad_w[] += err * x[]
        grad_b[] += err
        loss[] += 0.5 * err^2
        nseen[] += 1
        return (;)
    end

    function _process_manager_precompile_context(worker)
        return context(worker)[ProcessManagerPrecompileStep]
    end

    function _process_manager_precompile_reset!(ctx)
        ctx.grad_w[] = 0.0
        ctx.grad_b[] = 0.0
        ctx.loss[] = 0.0
        ctx.nseen[] = 0
        return ctx
    end

    function _process_manager_precompile_flush!(state, worker_values)
        total_grad_w = 0.0
        total_grad_b = 0.0
        total_loss = 0.0
        total_seen = 0

        for worker in worker_values
            ctx = _process_manager_precompile_context(worker)
            total_grad_w += ctx.grad_w[]
            total_grad_b += ctx.grad_b[]
            total_loss += ctx.loss[]
            total_seen += ctx.nseen[]
            _process_manager_precompile_reset!(ctx)
        end

        if total_seen > 0
            params = state.params[]
            scale = inv(total_seen)
            next_params = (;
                w = params.w - state.lr * total_grad_w * scale,
                b = params.b - state.lr * total_grad_b * scale,
            )
            state.params[] = next_params
            state.total_loss[] = total_loss

            for worker in worker_values
                _process_manager_precompile_context(worker).params[] = next_params
            end
        end

        return state
    end

    @compile_workload begin
        fake_events = Int[]
        fake_recipe = (;
            makeworker = (idx, manager) -> _ProcessPrecompileFakeWorker(idx, 0, false),
            loadjob! = (slot, job, manager) -> begin
                slot.worker.value = job
                slot.worker.done = false
            end,
            start! = (slot, job, manager) -> (slot.worker.done = true),
            isdone = (slot, manager) -> slot.worker.done,
            finalize! = (slot, job, manager) -> nothing,
            afterjob! = (slot, job, manager) -> begin
                push!(fake_events, slot.worker.value)
                slot.worker.value = 0
            end,
            sync_to_state! = manager -> length(fake_events),
            close! = (slot, manager) -> (slot.worker.done = true),
        )
        fake_manager = ProcessManager(
            fake_recipe;
            nworkers = 2,
            sync_policy = SyncEvery(2; drain = true),
            job_type = Int,
            result_type = Nothing,
        )
        run!(fake_manager, 1:3)
        close(fake_manager)

        noflush_manager = ProcessManager(
            fake_recipe;
            nworkers = 1,
            sync_policy = NoSync(),
            job_type = Int,
            result_type = Nothing,
        )
        dispatch!(noflush_manager, 1)
        poll!(noflush_manager)
        drain!(noflush_manager)
        close(noflush_manager)

        no_drain_manager = ProcessManager(
            fake_recipe;
            nworkers = 1,
            sync_policy = SyncEvery(1; drain = false),
            job_type = Int,
            result_type = Nothing,
        )
        run!(no_drain_manager, 1:2)
        close(no_drain_manager)

        jobs = [(; x = 0.1, y = 0.2), (; x = 0.3, y = 0.4)]
        template = Process(ProcessManagerPrecompileStep; repeats = 1)
        recipe = (;
            initstate = config -> (;
                params = Ref(config.initial_params),
                lr = config.lr,
                total_loss = Ref(0.0),
            ),
            makeworker = (idx, manager) -> template,
            loadjob! = (slot, job, manager) -> begin
                ctx = _process_manager_precompile_context(slot.worker)
                ctx.x[] = job.x
                ctx.y[] = job.y
                ctx.params[] = manager.state.params[]
                resetworker!(slot)
            end,
            providearguments = (slot, job, manager) -> (;),
            sync_to_state! = manager -> _process_manager_precompile_flush!(manager.state, workers(manager)),
        )

        manager = ProcessManager(
            recipe;
            nworkers = 2,
            config = (; initial_params = (w = 0.0, b = 0.0), lr = 0.01),
            sync_policy = SyncAtEnd(),
            job_type = eltype(jobs),
            result_type = typeof(template),
        )
        run!(manager, jobs)
        close(manager)

        reinit_worker = Process(
            _ProcessPrecompileCounter,
            Input(_ProcessPrecompileCounter, :value => 0);
            repeats = 1,
        )
        reinit_recipe = (;
            loadjob! = (slot, job, manager) -> reinitworker!(
                slot,
                Input(_ProcessPrecompileCounter, :value => job),
            ),
            afterjob! = (slot, job, manager) -> getticks(slot.worker),
        )
        reinit_manager = ProcessManager(
            reinit_recipe;
            workers = [reinit_worker],
            sync_policy = NoSync(),
            job_type = Int,
            result_type = typeof(reinit_worker),
        )
        run!(reinit_manager, 1:2)
        close(reinit_manager)

        # One Process per job, made when the job starts and dropped after it, on threads.
        ondemand_outputs = Vector{Any}(nothing, 2)
        ondemand_recipe = (;
            makeworker = (idx, manager, job) -> Process(_ProcessPrecompileCounter, Input(_ProcessPrecompileCounter, :value => job); repeats = 2),
            afterjob! = (slot, job, manager) -> (ondemand_outputs[job] = fetch(slot.result); slot.worker = nothing),
        )
        ondemand_manager = ProcessManager(
            ondemand_recipe;
            nworkers = 2,
            worker_lifecycle = OnDemandWorkers(destroy_after_finalize = true),
            worker_type = Process,
            sync_policy = NoSync(),
            execution = ThreadedWorkers(Dynamic()),
            job_type = Int,
            result_type = Any,
        )
        run!(ondemand_manager, 1:2)
        close(ondemand_manager)
    end
end
#== end: manager ==#
