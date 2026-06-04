include("_env.jl")

struct SourceAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct CombineAlgo <: StatefulAlgorithms.ProcessAlgorithm end
struct SinkAlgo <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.step!(::SourceAlgo, context)
    return (; produced = 2, passthrough = context.seed)
end

function StatefulAlgorithms.step!(::CombineAlgo, context)
    return (; combined = context.left + context.right)
end

function StatefulAlgorithms.step!(::SinkAlgo, context)
    return (; seen = context.value)
end

scaled_double(x; scale = 1) = scale * (2x)

n = 10
algo = @CompositeAlgorithm begin
    @state seed = 3
    @state doubled = 10
    @alias source = SourceAlgo
    produced, passthrough = source(seed = seed)
    doubled = @interval n scaled_double(produced; scale = 2)
    combined = CombineAlgo(left = passthrough, right = doubled)
    SinkAlgo(value = combined)
end

resolved = resolve(algo)
@assert resolved isa StatefulAlgorithms.LoopAlgorithm
@assert StatefulAlgorithms.getplan(resolved) isa CompositeAlgorithm
@assert intervals(resolved) == (1, 10, 1, 1)
@assert StatefulAlgorithms.getkey(StatefulAlgorithms.getalgo(resolved, 1)) == :source
@assert length(StatefulAlgorithms.getstates(resolved)) == 1
@assert StatefulAlgorithms.getkey(first(StatefulAlgorithms.getstates(resolved))) == :_state

process_repeat = Process(resolved, repeat = 10)
@assert repeats(StatefulAlgorithms.lifetime(process_repeat)) == 10

process_indefinite = Process(resolved, repeat = Inf)
@assert StatefulAlgorithms.lifetime(process_indefinite) isa Indefinite

opts = StatefulAlgorithms.getoptions(resolved)
sharedcontexts, sharedvars = StatefulAlgorithms._resolve_options(resolved)
@assert opts == StatefulAlgorithms.merge_nested_namedtuples(sharedvars, sharedcontexts)

wrapped = FuncWrapper(x -> 2x, (:x,), (:y,))
@assert StatefulAlgorithms.step!(wrapped, (; x = 4)) == (; y = 8)
@assert StatefulAlgorithms.init(wrapped, (; x = 4)) == (; y = 8)

kw_wrapped = FuncWrapper((x; scale = 1) -> scale * x, (:external,), (:y,), (; scale = 3))
StatefulAlgorithms.step!(kw_wrapped, (;external = 4))
@assert StatefulAlgorithms.step!(kw_wrapped, (; external = 4)) == (; y = 12)
@assert StatefulAlgorithms.init(kw_wrapped, (; external = 4)) == (; y = 12)

kw_from_context = FuncWrapper((x; scale = 1) -> scale * x, (:external,), (:y,), (; scale = :factor))
@assert StatefulAlgorithms.step!(kw_from_context, (; external = 4, factor = 5)) == (; y = 20)
@assert StatefulAlgorithms.init(kw_from_context, (; external = 4, factor = 5)) == (; y = 20)

kw_same_name = FuncWrapper((x; scale = 1) -> scale * x, (:external,), (:y,), (:scale,))
@assert StatefulAlgorithms.step!(kw_same_name, (; external = 4, scale = 6)) == (; y = 24)
@assert StatefulAlgorithms.init(kw_same_name, (; external = 4, scale = 6)) == (; y = 24)

state = @state begin
    a = 1
    b
end

@assert StatefulAlgorithms.init(state, (; b = 4)) == (; a = 1, b = 4)
@assert StatefulAlgorithms.init(state, (; a = 7, b = 4)) == (; a = 7, b = 4)

named_state_algo = @CompositeAlgorithm begin
    @state mystate begin
        a = 1
    end
    SinkAlgo(value = a)
end

resolved_named_state = resolve(named_state_algo)
@assert StatefulAlgorithms.getkey(first(StatefulAlgorithms.getstates(resolved_named_state))) == :mystate

repeated = @CompositeAlgorithm begin
    @state produced = 5
    tripled = @repeat 3 begin
        tripled = scaled_double(produced; scale = 3)
    end
end

resolved_repeated = resolve(repeated)
@assert resolved_repeated isa StatefulAlgorithms.LoopAlgorithm
@assert StatefulAlgorithms.getplan(resolved_repeated) isa CompositeAlgorithm
@assert StatefulAlgorithms.getalgo(resolved_repeated, 1) isa StatefulAlgorithms.AbstractIdentifiableAlgo
@assert StatefulAlgorithms.getalgo(StatefulAlgorithms.getalgo(resolved_repeated, 1)) isa Routine
@assert repeats(StatefulAlgorithms.getalgo(StatefulAlgorithms.getalgo(resolved_repeated, 1))) == (3,)

routine = @Routine begin
    @state produced = 5
    tripled = @repeat 3 scaled_double(produced; scale = 3)
end

resolved_routine = resolve(routine)
@assert resolved_routine isa StatefulAlgorithms.LoopAlgorithm
@assert StatefulAlgorithms.getplan(resolved_routine) isa Routine
@assert repeats(resolved_routine) == (3,)

p = Process(resolved, 10)
cn = fetch(run(p))
