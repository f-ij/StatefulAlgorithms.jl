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
selector tuple lives in the type so generated composite steps can specialize on
the context reads while the predicate function remains a value.
"""
struct RunIf{Vars, F, I}
    cond::F
    interval::I
end

getinterval(i::Interval{I, First, Offset}) where {I, First, Offset} = I
getinterval(::Type{<:Interval{I}}) where {I} = I

Interval(i::Int) = Interval{i, :end, 0}()
function Interval(i::Int, first::Int, offset::Int = 0)
    @assert offset >= 0
    @assert i > 0
    Interval{i, mod1(first, i), offset}()
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
RunIf(interval::I, cond::F, vars...) where {I<:Interval, F<:Function} = RunIf{vars, typeof(cond), typeof(interval)}(cond, interval)
RunIf(interval::R, cond::F, vars...) where {R<:Real, F<:Function} = RunIf(Interval(interval), cond, vars...)

@inline getcondition(runif::R) where {R<:RunIf} = getfield(runif, :cond)
@inline getinterval(runif::R) where {R<:RunIf} = getinterval(getfield(runif, :interval))
getinterval(::Type{<:RunIf{V, F, I}}) where {V, F, I} = getinterval(I)
@inline schedule_interval(interval::I) where {I<:Interval} = interval
@inline schedule_interval(runif::R) where {R<:RunIf} = getfield(runif, :interval)

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

Base.length(i::I) where {I<:Interval} = 1

##########################################
########### Combining entries ############
##########################################

function Base.:(*)(num::N, interval::Interval{I, First, Offset}) where {N<:Real, I, First, Offset}
    @assert First == :start || First == :end "When multiplying an integer with an Interval, the first argument must be either :start or :end, otherwise the result is not well defined."
    Interval(num*I, First, Offset)
end
Base.:(*)(interval::Interval{I, First, Offset}, num::N) where {I, First, Offset, N<:Real} = Interval(num*I, First, Offset)

function Base.:(*)(interval1::Interval{I1, First1, Offset1}, interval2::Interval{I2, First2, Offset2}) where {I1, First1, Offset1, I2, First2, Offset2}
    @assert (First1 == :start && First2 == :start) || (First1 == :end && First2 == :end) "When multiplying two Intervals, both must have the same first argument (:start or :end), otherwise the result is not well defined."
    Interval(I1*I2, First1, Offset1*I2 + Offset2*I1)
end

Base.:(*)(runif::RunIf{Vars}, interval::I) where {Vars, I<:Interval} =
    RunIf(schedule_interval(runif) * interval, getcondition(runif), Vars...)
Base.:(*)(interval::I, runif::RunIf{Vars}) where {I<:Interval, Vars} =
    RunIf(interval * schedule_interval(runif), getcondition(runif), Vars...)
Base.:(*)(runif::RunIf{Vars}, num::N) where {Vars, N<:Real} =
    RunIf(schedule_interval(runif) * num, getcondition(runif), Vars...)
Base.:(*)(num::N, runif::RunIf{Vars}) where {N<:Real, Vars} =
    RunIf(num * schedule_interval(runif), getcondition(runif), Vars...)

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
# `getcondition`, `Vars`).
@inline should_run_schedule(interval::I, loopidx::Int, context::C) where {I<:Interval, C} = @inline divides(loopidx, interval)

@inline function should_run_schedule(runif::R, loopidx::Int, context::C) where {Vars, R<:RunIf{Vars}, C}
    if !(@inline divides(loopidx, runif))
        return false
    end
    if isempty(Vars)
        return @inline getcondition(runif)()
    end
    return @inline getcondition(runif)(getindex(context, Vars...))
end

@inline always_runs(::Type{I}) where {F, I<:Interval{1, F, 0}} = true

@inline compute_multiplier(i::I) where {I<:Interval} = 1 / getinterval(i)
@inline compute_multiplier(runif::R) where {R<:RunIf} = 1 / getinterval(runif)
