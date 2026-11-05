#=
Schedule entries of a composite plan: when a child runs, counted in ticks of its composite (the composite's own step
counter, from 1).

1. Types and constructors   `Interval{I, First, Offset}` (every `I` ticks) and `RunIf` (an interval plus a condition)
2. Tick arithmetic          `%` and `divides`: whether a tick is one the entry runs on
3. Combining entries        `*` multiplies intervals when a nested composite is flattened into its parent
                            (`flatten_comp_funcs`, Fusing.jl); `lcm` gives the period of a schedule

The hook methods (`should_run_schedule`, `always_runs`, `compute_multiplier`) are in the section at the end.
=#

export Interval, RunIf

##########################################
######## Types and constructors ##########
##########################################

"""
    Interval(i[, first[, offset]])

Composite schedule entry that runs a child once every `i` ticks of its composite. `first` says which tick of each
period it runs on: `:end` (the default, ticks `i, 2i, ...`), `:start` (ticks `1, i+1, ...`) or a number `k` (ticks `k,
k+i, ...`, `k` taken modulo `i`). With an `offset`, the child skips the first `offset` ticks and then keeps the same
ticks: `Interval(3, :start, 4)` runs on 7, 10, .... The three are type parameters, so a step can test them at compile
time; `Interval(1)` is `always_runs`.
"""
struct Interval{I, First, Offset} end

"""
Composite schedule entry that runs a child only when a context predicate passes.

`RunIf(cond, vars...)` defaults to every loop tick. `RunIf(interval, cond,
vars...)` combines normal interval scheduling with a runtime predicate. The
selectors (`Var`s) are a field: their types decide the context reads while compiling, and a `Var` of a `Unique`
handle may hold its id as data (`Var`), which must stay out of types.
"""
struct RunIf{V<:Tuple, F, I}
    cond::F
    interval::I
    vars::V
end

getinterval(i::Interval{I, First, Offset}) where {I, First, Offset} = I
getinterval(::Type{<:Interval{I}}) where {I} = I

Interval(i::Int) = Interval{i, :end, 0}()
# A first tick of `i` is `:end` and of 1 is `:start`, so one schedule has one type (`Interval(3, 3) == Interval(3)`).
function Interval(i::Int, first::Int, offset::Int = 0)
    @assert offset >= 0
    @assert i > 0
    tick = mod1(first, i)
    tick == i && return Interval{i, :end, offset}()
    tick == 1 && return Interval{i, :start, offset}()
    Interval{i, tick, offset}()
end
function Interval(i::Int, first::Symbol, offset::Int = 0)
    @assert offset >= 0
    @assert i > 0
    @assert first == :start || first == :end
    Interval{i, first, offset}()
end
Interval(f::R, first::F = :end, offset::O = 0) where {R<:Real, F, O<:Real} = Interval(round(Int, f), first, round(Int, offset))

# `vars...` stays untyped: the selectors differ in type, and a typed `Vararg{V}` takes only one type.
RunIf(cond::F, vars...) where {F<:Function} = RunIf(Interval(1), cond, vars...)
RunIf(interval::I, cond::F, vars...) where {I<:Interval, F<:Function} = RunIf{typeof(vars), typeof(cond), typeof(interval)}(cond, interval, vars)
RunIf(interval::R, cond::F, vars...) where {R<:Real, F<:Function} = RunIf(Interval(interval), cond, vars...)

@inline getcondition(runif::R) where {R<:RunIf} = getfield(runif, :cond)
@inline getvars(runif::R) where {R<:RunIf} = getfield(runif, :vars)
@inline getinterval(runif::R) where {R<:RunIf} = getinterval(getfield(runif, :interval))
getinterval(::Type{<:RunIf{V, F, I}}) where {V, F, I} = getinterval(I)
@inline schedule_interval(interval::I) where {I<:Interval} = interval
@inline schedule_interval(runif::R) where {R<:RunIf} = getfield(runif, :interval)

"""How many ticks of its composite a schedule entry skips at the start (its `Offset`), from the type alone."""
getoffset(::Type{<:Interval{I, First, Offset}}) where {I, First, Offset} = Offset
getoffset(::Type{<:RunIf{V, F, I}}) where {V, F, I} = getoffset(I)

##########################################
############ Tick arithmetic #############
##########################################

# `num % interval == 0` on the ticks the entry runs on; before tick `Offset + 1` it returns `num` (never 0).
@inline function Base.:(%)(num::N, interval::Interval{I, First, Offset}) where {N<:Integer, I, First, Offset}
    if Offset == 0
        return (num - First) % I
    else
        if num > Offset
            return (num - First) % I
        else
            return num
        end
    end
end

@inline function Base.:(%)(num::N, i::Interval{I, :end, Offset}) where {N<:Integer, I, Offset}
    if Offset == 0
        return num % I
    else
        if num > Offset
            return num % I
        else
            return num
        end
    end
end

@inline function Base.:(%)(num::N, i::Interval{I, :start, Offset}) where {N<:Integer, I, Offset}
    if Offset == 0
        return (num - 1) % I
    else
        if num > Offset
            return (num - (I+1)) % I
        else
            return num
        end
    end
end

@inline function divides(num::N, interval::Interval{I, First}) where {N<:Integer, I, First}
    return @inline (num % interval == 0)
end

@inline function divides(num::N, interval::Interval{1, F, Offset}) where {N<:Integer, F, Offset}
    if Offset == 0
        return true
    else
        if num > Offset
            return true
        else
            return false
        end

    end
end

@inline function divides(num::N, int::M) where {N<:Integer, M<:Integer}
    return num % int == 0
end

@inline divides(num::N, runif::R) where {N<:Integer, R<:RunIf} = @inline divides(num, schedule_interval(runif))

"""
    counter_cycle(EntryTypes::Tuple) -> (last, restart)

How the tick counter of a composite with schedule entries of types `EntryTypes` cycles: `1, 2, ..., last`, then back
to `restart`, with `restart = max offset + 1` and `last = max offset + lcm of the intervals`. Restarting past every
offset makes an offset skip ticks once, at the start of a run; a period of the lcm keeps every child on its ticks (the
lcm is a multiple of each interval, so `(tick - First) % I` is the same after the wrap). Without offsets the counter
cycles `1:lcm`. Used by `inc!` (CompositeAlgorithms.jl, Packaging/Step.jl).
"""
function counter_cycle(entry_types::T) where {T<:Tuple}
    offset = maximum(getoffset, entry_types; init = 0)
    period = lcm(map(getinterval, entry_types)...)
    return offset + period, offset + 1
end

Base.length(i::I) where {I<:Interval} = 1

##########################################
########### Combining entries ############
##########################################

"""
    child * parent

The schedule of a child with schedule `child` inside a nested composite that runs on `parent`, in ticks of the
parent's composite: what the child gets when the nested composite is flattened into its parent. A number `n` is
`Interval(n)`.

The nested composite runs on the parent ticks `t0, t0+P, ...` (`P` the parent's interval; `t0` its first tick after
the parent's offset), and its `k`-th run is the child's tick `k`. A child running every `C` of its ticks from tick
`c`, skipping its first `Oc`, so runs every `C*P` parent ticks from tick `t0 + (c-1)*P`, skipping the parent ticks
before `t0 + Oc*P`. An offset that skips no tick is dropped, so the result has one type per schedule.
"""
function Base.:(*)(child::Interval{I1, First1, Offset1}, parent::Interval{I2, First2, Offset2}) where {I1, First1, Offset1, I2, First2, Offset2}
    p = first_tick(parent)
    t0 = p > Offset2 ? p : p + I2 * cld(Offset2 - p + 1, I2)
    period = I1 * I2
    first = mod1(t0 + (first_tick(child) - 1) * I2, period)
    offset = t0 + Offset1 * I2 - 1
    Interval(period, first, offset < first ? 0 : offset)
end
Base.:(*)(child::I, num::N) where {I<:Interval, N<:Real} = child * Interval(num)
Base.:(*)(num::N, parent::I) where {N<:Real, I<:Interval} = Interval(num) * parent

"""The tick of each period an interval runs on, as a number in `1:I`."""
first_tick(::Interval{I, :end, Offset}) where {I, Offset} = I
first_tick(::Interval{I, :start, Offset}) where {I, Offset} = 1
first_tick(::Interval{I, First, Offset}) where {I, First, Offset} = First

Base.:(*)(runif::R, interval::I) where {R<:RunIf, I<:Interval} =
    RunIf(schedule_interval(runif) * interval, getcondition(runif), getvars(runif)...)
Base.:(*)(interval::I, runif::R) where {I<:Interval, R<:RunIf} =
    RunIf(interval * schedule_interval(runif), getcondition(runif), getvars(runif)...)
Base.:(*)(runif::R, num::N) where {R<:RunIf, N<:Real} =
    RunIf(schedule_interval(runif) * num, getcondition(runif), getvars(runif)...)
Base.:(*)(num::N, runif::R) where {N<:Real, R<:RunIf} =
    RunIf(num * schedule_interval(runif), getcondition(runif), getvars(runif)...)

function Base.lcm(is::Vararg{Union{Interval, RunIf}, N}) where {N}
    nums = getinterval.(is)
    return lcm(nums...)
end

##########################################
########## Hook extensions ###############
##########################################
# The schedule-entry hooks (Hooks.jl):
# - `should_run_schedule`: an `Interval` runs on the ticks it divides (`divides`), a `RunIf` on those of its interval
#   when its condition holds;
# - `always_runs`: only `Interval(1)` without an offset; with an offset it skips the first `Offset` ticks;
# - `compute_multiplier`: a child with interval `n` runs once every `n` runs of its plan, so `1/n` times per run. A
#   `RunIf` counts as its interval; how often its condition holds is not known before the run.

# TODO: check these two `should_run_schedule` methods and the names they use (`should_run_schedule`, `divides`,
# `getcondition`, `getvars`).
@inline should_run_schedule(interval::I, loopidx::Int, context::C) where {I<:Interval, C} = @inline divides(loopidx, interval)

@inline function should_run_schedule(runif::R, loopidx::Int, context::C) where {V, R<:RunIf{V}, C}
    if !(@inline divides(loopidx, runif))
        return false
    end
    if V === Tuple{}
        return @inline getcondition(runif)()
    end
    return @inline getcondition(runif)(getindex(context, getvars(runif)...))
end

@inline always_runs(::Type{I}) where {F, I<:Interval{1, F, 0}} = true

@inline compute_multiplier(i::I) where {I<:Interval} = 1 / getinterval(i)
@inline compute_multiplier(runif::R) where {R<:RunIf} = 1 / getinterval(runif)
