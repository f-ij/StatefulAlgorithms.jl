using Test
using StatefulAlgorithms

const RB = StatefulAlgorithms

# Building a plan's registry (step 1 of `resolve`): `build_registry_and_key_plan` works the layout out from the
# plan's type while compiling (the generated path), or from the values at run time (`build_registry_from_values`).

@StepAlgorithm function RBCount(@managed(n = 0))
    @update n = n + 1
end
@StepAlgorithm function RBScale(@managed(x = 1.0))
    @update x = 0.5 * x
end
@StepAlgorithm function RBSink(value)
    return nothing
end
struct RBSrc <: ProcessAlgorithm end
RB.init(::RBSrc, c) = (; x = 0.0)
RB.step!(::RBSrc, c) = (; x = c.x + 1.0)
struct RBDst <: ProcessAlgorithm end
RB.init(::RBDst, c) = (; acc = 0.0)
RB.step!(::RBDst, c) = (; acc = c.acc + c.u)
rb_half(x) = 0.5 * x

"""The `LoopAlgorithm` `resolve` sets up the registry of: the plan wrapped, finalized plans unwrapped, ids normalized."""
function rb_loopalgorithm(plan)
    la = plan isa RB.FinalizedAlgorithm ? RB.LoopAlgorithm(RB.inneralgorithm(plan)) : RB.LoopAlgorithm(plan)
    return first(RB.normalize_ids(la))
end

"""Whether the compiled `build_registry_and_key_plan` for `la` sets the registry up at run time."""
rb_uses_runtime_path(la) =
    occursin("build_registry_from_values", string(Base.code_typed(RB.build_registry_and_key_plan, (typeof(la),))[1][1].code))

"""Whether two `(registry, keyed la)` results are the same: types, keys, multipliers and lookup tables."""
function rb_same_setup(a, b)
    typeof(a) === typeof(b) || return false
    repr(a[1]) == repr(b[1]) || return false
    return all(zip(RB.getentries(a[1]), RB.getentries(b[1]))) do (x, y)
        RB.getmultipliers(x) == RB.getmultipliers(y) && RB.getdynamiclookup(x) == RB.getdynamiclookup(y)
    end
end

shared_phase = Unique(@state begin
    total = 0.0
    x = 1.0
end)
fwd = @Routine begin
    @alias ps = shared_phase
    ps
    RBSink(value = ps.x)
end
u1, u2 = Unique(RBSrc), Unique(RBSrc)

rb_shared_states = @CompositeAlgorithm begin
    fwd()
    fwd()
end
rb_dsl_routes = @CompositeAlgorithm begin
    @alias s = RBSrc
    @alias d = RBDst
    s()
    d()
    @route s.x => d.u
end
rb_dsl_calls = @CompositeAlgorithm begin
    @state seed = 1.0
    y = rb_half(seed)
    RBSink(value = y)
end
rb_dsl_local = @Routine begin
    local acc
    acc = 2.0
    acc = rb_half(acc)
    RBCount()
end

# Plans whose layout follows from their type: the generated path is taken.
const RB_TYPED_PLANS = Pair{String,Any}[
    "flat composite" => CompositeAlgorithm(RBCount, RBScale, RBSrc, (1, 1, 1)),
    "intervals" => CompositeAlgorithm(RBCount, RBScale, (1, 3)),
    "nested composite" => CompositeAlgorithm(CompositeAlgorithm(RBCount, RBScale, (1, 2)), RBSrc, (1, 1)),
    "Routine in Routine" => Routine(Routine(RBCount, RBScale, (1, 2)), RBSrc, (3, 1)),
    "Routine in composite" => CompositeAlgorithm(Routine(RBCount, RBScale, (2, 1)), RBCount, (1, 2)),
    "threaded" => ThreadedCompositeAlgorithm(RBCount, Routine(RBCount, RBScale, (2, 1)), (1, 3)),
    "same algorithm twice" => CompositeAlgorithm(RBCount, Routine(RBCount, RBScale, (2, 1)), (1, 3)),
    "given key first" => CompositeAlgorithm(:a => RBSrc, RBSrc, RBCount, (1, 2, 1)),
    "given key replaces autokey" => CompositeAlgorithm(RBSrc, RBCount, :a => RBSrc, (1, 1, 3)),
    "nested Unique handles" => CompositeAlgorithm(Routine(u1, u2, RBSrc, (1, 2, 1)), CompositeAlgorithm(u1, RBCount, (1, 1)), u2, (1, 1, 2)),
    "shared Unique @state" => rb_shared_states,
    "DSL with routes" => rb_dsl_routes,
    "DSL with @state and calls" => rb_dsl_calls,
    "DSL routine with a local" => rb_dsl_local,
    "finalized" => finalstep(Routine(RBCount, RBScale, (2, 3)), x -> x),
]

# Two named states with the same key in different blocks are merged into one: the merge needs the values.
merge1 = @Routine begin
    @state rbshared begin
        a = 1
    end
    RBSink(value = a)
end
merge2 = @Routine begin
    @state rbshared begin
        b = 2
    end
    RBSink(value = b)
end
const RB_MERGE_PLAN = CompositeAlgorithm(merge1, merge2, (1, 2))

@testset "Registry build: the generated path is taken for the usual plan shapes" begin
    for (name, plan) in RB_TYPED_PLANS
        @testset "$name" begin
            @test !rb_uses_runtime_path(rb_loopalgorithm(plan))
        end
    end
    @test rb_uses_runtime_path(rb_loopalgorithm(RB_MERGE_PLAN))
end

@testset "Registry build: the generated path gives the run-time path's registry" begin
    for (name, plan) in [RB_TYPED_PLANS; "merged named states" => RB_MERGE_PLAN]
        @testset "$name" begin
            la = rb_loopalgorithm(plan)
            @test rb_same_setup(RB.build_registry_and_key_plan(la), RB.build_registry_from_values(la))
        end
    end
    # The registries themselves, for a few of them.
    keys_of(plan) = RB.all_keys(RB.getregistry(resolve(plan)))
    @test keys_of(CompositeAlgorithm(RBCount, Routine(RBCount, RBScale, (2, 1)), (1, 3))) == (:RBCount_1, :RBScale_1)
    @test keys_of(CompositeAlgorithm(RBSrc, RBCount, :a => RBSrc, (1, 1, 3))) == (:a, :RBCount_1)
    reg = RB.getregistry(resolve(CompositeAlgorithm(RBCount, Routine(RBCount, RBScale, (2, 1)), (1, 3))))
    # Once per step, plus twice per run of the Routine, which runs every third step.
    @test RB.getmultipliers(RB.getentries(reg)[1]) ≈ [1.0 + 2.0 / 3.0]
    merged = RB.initcontext(resolve(RB_MERGE_PLAN))
    @test merged[:rbshared].a == 1 && merged[:rbshared].b == 2
end

rb_plus_one(x) = x + 1.0

@testset "Registry build: the states of a named nested plan are registered" begin
    inner = @CompositeAlgorithm begin
        @state x = 0.0
        x = rb_plus_one(x)
    end
    # A nested plan given a name (`insert` allows it): its states are registered as an unnamed plan's are.
    named = insert(CompositeAlgorithm(RBCount, (1,)), 2, IdentifiableAlgo(inner, :named))
    la = rb_loopalgorithm(named)
    @test rb_same_setup(RB.build_registry_and_key_plan(la), RB.build_registry_from_values(la))
    @test RB.all_keys(RB.getregistry(resolve(named))) == (:_state_1, :RBCount_1)
    @test RB.context(run(named; repeats = 3))[:_state_1].x == 3.0
end

@testset "Registry build: `add` and `RegistryBuilder`" begin
    handle = IdentifiableAlgo(RBCount())
    reg, keyed = RB.add(RB.NameSpaceRegistry(), handle, 2.0)
    @test RB.getkey(keyed) == :RBCount_1
    reg, again = RB.add(reg, handle, 1.0)
    @test again === keyed
    @test RB.getmultipliers(RB.getentries(reg)[1]) == [3.0]
    builder = RB.RegistryBuilder(reg)
    @test RB.getkey(RB.add!(builder, IdentifiableAlgo(RBScale()), 1.0)) == :RBScale_1
    @test RB.all_keys(RB.registry(builder)) == (:RBCount_1, :RBScale_1)
end

# Rule methods of algorithms defined here (after the package was loaded).
struct RBRenamed <: ProcessAlgorithm end
RB.init(::RBRenamed, c) = (; x = 0.0)
RB.step!(::RBRenamed, c) = (; x = c.x + 1.0)
struct RBCustom <: ProcessAlgorithm end
RB.init(::RBCustom, c) = (; x = 0.0)
RB.step!(::RBCustom, c) = (; x = c.x + 1.0)
RB.autokey_basename(::Union{RBCustom, Type{<:RBCustom}}) = :Custom

@testset "Registry build: changing a rule updates prepared plan types" begin
    keys_of(plan) = RB.all_keys(RB.getregistry(resolve(plan)))
    renamed() = CompositeAlgorithm(RBRenamed, RBCount, (1, 2))
    @test keys_of(renamed()) == (:RBRenamed_1, :RBCount_1)
    # A new rule method for an algorithm whose plan type is prepared already: the next resolve uses it.
    @eval RB.autokey_basename(::Union{RBRenamed, Type{<:RBRenamed}}) = :Renamed
    @test keys_of(renamed()) == (:Renamed_1, :RBCount_1)
    # Redefined (as Revise does).
    @eval RB.autokey_basename(::Union{RBRenamed, Type{<:RBRenamed}}) = :Again
    @test keys_of(renamed()) == (:Again_1, :RBCount_1)
    # A rule method defined before the first resolve: both paths agree.
    la = rb_loopalgorithm(CompositeAlgorithm(RBCustom, RBCustom, (1, 2)))
    @test RB.all_keys(RB.build_registry_and_key_plan(la)[1]) == (:Custom_1,)
    @test rb_same_setup(RB.build_registry_and_key_plan(la), RB.build_registry_from_values(la))
    # Plans that ask no changed rule keep the generated path.
    @test !rb_uses_runtime_path(rb_loopalgorithm(CompositeAlgorithm(RBCount, RBScale, (1, 2))))
end
