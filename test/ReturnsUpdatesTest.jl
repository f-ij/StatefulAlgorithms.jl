using Test
using StatefulAlgorithms
const SAru = StatefulAlgorithms

# A step's return is a value; `@update` writes an argument back (see docs/src/user/migrating_dsl.md).

@StepAlgorithm function RUCounter(@managed(count = 0))
    @update count = count + 1
    return 2.0 * count
end

@StepAlgorithm function RUPair(@managed(count = 0))
    @update count += 1
    return (; E = 1.0 * count, M = -1.0 * count)
end

@StepAlgorithm function RUTuple(@managed(count = 0))
    @update count += 1
    return (count, 10 * count)
end

# State field `x`; returns a different value, `-x`.
@StepAlgorithm function RUFieldX(@managed(x = 100))
    @update x = x + 1
    return -x
end

@StepAlgorithm function RUAddOne!(val)
    @update val = val + 1
end

@StepAlgorithm function RUAddTwo!(val)
    @update val += 2
end

@StepAlgorithm function RUMaybe!(val, flag)
    if flag
        @update val = val + 1
    end
    return
end

@StepAlgorithm function RUProbe(v)
    return v
end

struct RUHandWritten <: ProcessAlgorithm end
StatefulAlgorithms.init(::RUHandWritten, context) = (; total = 0)
StatefulAlgorithms.step!(::RUHandWritten, context) = StepReturn(context.total * 10, StateUpdates(; total = context.total + 1))

ru_record!(v, x) = (push!(v, x); nothing)
ru_record!(v, xs...) = (push!(v, xs); nothing)
ru_record_sum!(v, x, y) = (push!(v, x + y); nothing)
ru_true() = true

@testset "Returns are values, updates are written back" begin
    @testset "`y = Algo()`, `(; a, b) = Algo()`, `a, b = Algo()` capture the return" begin
        seen = Any[]
        c = @CompositeAlgorithm begin
            y = RUCounter()
            (; E) = RUPair()
            a, b = RUTuple()
            ru_record!(seen, y, E, a, b)
        end
        run(c; repeats = 2)
        @test seen == [(2.0, 1.0, 1, 10), (4.0, 2.0, 2, 20)]
    end

    @testset "`@update` writes the algorithm's state, the block's state, a local and a captured return" begin
        p = InlineProcess(@Routine(begin
            @alias c = RUCounter()
            @repeat 3 c()
        end); repeats = 1)
        run(p)
        @test SAru.getcontext(p)[:c].count == 3

        p = InlineProcess(@CompositeAlgorithm(begin
            @state s = 0.0
            RUAddOne!(s)
        end); repeats = 3)
        run(p)
        @test SAru.getcontext(p)[:_state_1].s == 3.0

        seen = Float64[]
        @test_logs (:warn, r"`RUAddOne!` updates its argument `val`, so it changes `x` here") run(@CompositeAlgorithm(begin
            local x
            x = 0.0
            RUAddOne!(x)
            ru_record!(seen, x)
        end); repeats = 3)
        @test seen == [1.0, 1.0, 1.0]

        seen = Float64[]
        @test_logs (:warn, r"so it changes `y` here") run(@CompositeAlgorithm(begin
            y = RUCounter()
            RUAddOne!(y)
            ru_record!(seen, y)
        end); repeats = 2)
        @test seen == [3.0, 5.0]
    end

    @testset "`@mutable` says an update is intended: no warning, same result" begin
        seen = Float64[]
        @test_logs run(@CompositeAlgorithm(begin
            @mutable y = RUCounter()
            @mutable local x
            x = 0.0
            RUAddOne!(y)
            RUAddTwo!(x)
            ru_record_sum!(seen, y, x)
        end); repeats = 2)
        @test seen == [5.0, 7.0]
    end

    @testset "One algorithm at two positions: shared state, each position its own arguments" begin
        seen = Any[]
        p = InlineProcess(@CompositeAlgorithm(begin
            @mutable y = 10.0
            @mutable x = 0.0
            RUAddOne!(y)
            RUAddOne!(x)
            c1 = RUCounter()
            c2 = RUCounter()
            ru_record!(seen, y, x, c1, c2)
        end); repeats = 2)
        run(p)
        @test seen == [(11.0, 1.0, 2.0, 4.0), (11.0, 1.0, 6.0, 8.0)]
        @test SAru.getcontext(p)[RUCounter].count == 4   # one state, stepped twice per step
    end

    @testset "`@bind` rewires each position's own arguments" begin
        seen = Any[]
        run(@CompositeAlgorithm(begin
            @state src = 5.0
            @state t = 1.0
            @state u = 2.0
            @bind src => t begin
                p1 = RUProbe(t)
                p2 = RUProbe(u)
                ru_record!(seen, p1, p2)
            end
        end); repeats = 1)
        @test seen == [(5.0, 2.0)]

        inner() = @CompositeAlgorithm begin
            @state t = 1.0
            @state u = 2.0
            p1 = RUProbe(t)
            p2 = RUProbe(u)
            ru_record!(seen, p1, p2)
        end
        blk = inner()
        empty!(seen)
        run(@CompositeAlgorithm(begin
            @state src = 7.0
            @context n = blk()
            @bind src => n.t
        end); repeats = 1)
        @test seen == [(7.0, 2.0)]
    end

    @testset "An `@update` in a branch writes the value at the return" begin
        p = InlineProcess(@CompositeAlgorithm(begin
            @state s = 0.0
            @state flag = true
            RUMaybe!(s, flag)
        end); repeats = 3)
        run(p)
        @test SAru.getcontext(p)[:_state_1].s == 3.0
        p = InlineProcess(@CompositeAlgorithm(begin
            @state s = 0.0
            @state flag = false
            RUMaybe!(s, flag)
        end); repeats = 3)
        run(p)
        @test SAru.getcontext(p)[:_state_1].s == 0.0
    end

    @testset "An `@input` cannot be updated: an error when the block is built" begin
        err = try
            @CompositeAlgorithm begin
                @input t = 1.0
                RUAddOne!(t)
            end
            nothing
        catch e
            e
        end
        @test err isa ErrorException && occursin("`RUAddOne!` updates its argument `val`, which is `t` here: an `@input`", sprint(showerror, err))
    end

    @testset "`x = Algo()` captures the return even when Algo has a state field `x`" begin
        seen = Any[]
        result = run(@CompositeAlgorithm(begin
            x = RUFieldX()
            ru_record!(seen, x)
        end); repeats = 2)
        @test seen == [-101, -102]                          # the return, not the field
        @test SAru.context(result)[RUFieldX].x == 102       # the field changes only through `@update`
    end

    @testset "`(; a) = @state(X)` and `@state(X).a` read an algorithm's state" begin
        seen = Any[]
        run(@CompositeAlgorithm(begin
            RUCounter()
            (; count) = @state(RUCounter)
            ru_record!(seen, count)
        end); repeats = 3)
        @test seen == [1, 2, 3]

        seen = Any[]
        run(@CompositeAlgorithm(begin
            @alias c = RUCounter()
            c()
            ru_record!(seen, @state(c).count)
        end); repeats = 2)
        @test seen == [1, 2]

        err = try
            @eval @CompositeAlgorithm begin
                RUCounter()
                c = @state(RUCounter)
            end
            nothing
        catch e
            e
        end
        @test err isa LoadError && occursin("take fields of `@state(X)` by name", sprint(showerror, err.error))
    end

    @testset "A hand-written step returns a StepReturn" begin
        seen = Any[]
        p = InlineProcess(@CompositeAlgorithm(begin
            y = RUHandWritten()
            ru_record!(seen, y)
        end); repeats = 3)
        run(p)
        @test seen == [0, 10, 20]
        @test SAru.getcontext(p)[:RUHandWritten_1].total == 3
    end

    @testset "Capturing a return and updating cost no allocation per step" begin
        plan = @CompositeAlgorithm begin
            @state s = 0.0
            y = RUCounter()
            RUAddOne!(s)
            (; E) = RUPair()
        end
        small = InlineProcess(plan; repeats = 1_000); large = InlineProcess(plan; repeats = 101_000)
        run(small); run(large)
        @test (@allocated run(large)) == (@allocated run(small))
    end
end

@testset "@StepAlgorithm: returns and updates" begin
    @test updated_names(RUCounter) == (:count,)
    @test updated_names(RUAddOne!) == (:val,)
    @test updated_names(RUHandWritten) == ()

    # A returned name that is an argument does not write it back: the macro says so.
    @test_logs (:warn, r"`RUStale` returns `x`, which is also an argument") @eval @StepAlgorithm function RUStale(x)
        return (; x = x + 1)
    end

    # Only an argument can be updated.
    err = try
        @eval @StepAlgorithm function RUNotAnArgument(x)
            y = x
            @update y = 2
        end
        nothing
    catch e
        e
    end
    @test err isa LoadError && occursin("only an argument of the algorithm can be updated", sprint(showerror, err.error))

    # Called directly, a step returns its value.
    @test step!(RUAddOne!(), 1) === nothing
    @test step!(RUTuple(), @init((;))) == (1, 10)
end

@testset "Legacy macros keep the older rules" begin
    @test_logs (:warn, r"`@StepAlgorithm_legacy` is deprecated") @eval @StepAlgorithm_legacy function RULegacyCounter(@managed(count = 0))
        return (; count = count + 1, doubled = 2 * (count + 1))
    end
    global ru_legacy_seen = Any[]
    @test_logs (:warn, r"`@CompositeAlgorithm_legacy` is deprecated") @eval ru_legacy = @CompositeAlgorithm_legacy begin
        doubled = RULegacyCounter()
        ru_record!(ru_legacy_seen, doubled)
    end
    p = InlineProcess(ru_legacy; repeats = 3)
    run(p)
    # `doubled = Algo()` binds the returned field `doubled`; returning `count` updates it.
    @test ru_legacy_seen == [2, 4, 6]
    @test SAru.getcontext(p)[:RULegacyCounter_1].count == 3

    # In a legacy routine, a lifetime selector the statement assigns reads the repeated algorithm's field.
    @eval ru_legacy_routine = @Routine_legacy begin
        count = @repeat Until(x -> x >= 3, count) RULegacyCounter()
    end
    @test SAru.context(run(ru_legacy_routine; repeats = 1))[RULegacyCounter].count == 3

    # `x = @repeat spec Algo()` keeps its legacy meaning (an error with `@Routine`): `x` binds the returned field `x`
    # of the last repeat.
    global ru_legacy_repeat_seen = Any[]
    @eval ru_legacy_repeat = @Routine_legacy begin
        doubled = @repeat 2 RULegacyCounter()
        ru_record!(ru_legacy_repeat_seen, doubled)
    end
    run(ru_legacy_repeat; repeats = 2)
    @test ru_legacy_repeat_seen == [4, 8]
end
