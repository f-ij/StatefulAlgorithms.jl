export Interval, RunIf

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
Interval(i::Int, first::Int, offset::Int = 0) = Interval{i, mod1(first, i), round(Int, offset)}()
function Interval(i::Int, first::Symbol, offset::Int = 0)
    @assert offset >= 0
    @assert i > 0
    @assert first == :start || first == :end
    Interval{i, first, offset}()
end
Interval(f::Real, first = :end, offset = 0) = Interval(round(Int, f), first, offset)

RunIf(cond::Function, vars...) = RunIf(Interval(1), cond, vars...)
RunIf(interval::Interval, cond::Function, vars...) = RunIf{typeof(vars), typeof(cond), typeof(interval)}(cond, interval, vars)
RunIf(interval::Real, cond::Function, vars...) = RunIf(Interval(interval), cond, vars...)

@inline getcondition(runif::RunIf) = getfield(runif, :cond)
@inline getvars(runif::RunIf) = getfield(runif, :vars)
@inline getinterval(runif::RunIf) = getinterval(getfield(runif, :interval))
getinterval(::Type{<:RunIf{V, F, I}}) where {V, F, I} = getinterval(I)
@inline schedule_interval(interval::Interval) = interval
@inline schedule_interval(runif::RunIf) = getfield(runif, :interval)

@inline function Base.:(%)(num, interval::Interval{I, First, Offset}) where {I, First, Offset}
    if Offset == 0
        return (num - (First+1)) % I
    else
        if num > Offset
            return (num - (First+1)) % I
        else
            return num
        end
    end
end

@inline function Base.:(%)(num, i::Interval{I, :end, Offset}) where {I, Offset}
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

@inline function Base.:(%)(num, i::Interval{I, :start, Offset}) where {I, Offset}
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

@inline function divides(num, interval::Interval{I, First}) where {I, First}
    return @inline (num % interval == 0)
end

@inline function divides(num, interval::Interval{1, F, Offset}) where {F, Offset}
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

@inline function divides(num, int::I) where I
    return num % I == 0
end

@inline divides(num, runif::RunIf) = @inline divides(num, schedule_interval(runif))

# `should_run_schedule`, `always_runs`, `compute_multiplier` for these entries: HookExtensions.jl next to this file.

Base.length(i::Interval) = 1
function Base.:(*)(num, interval::Interval{I, First, Offset}) where {I, First, Offset}
    @assert First == :start || First == :end "When multiplying an integer with an Interval, the first argument must be either :start or :end, otherwise the result is not well defined."
    Interval(num*I, First, Offset)
end
Base.:(*)(interval::Interval{I, First, Offset}, num) where {I, First, Offset} = Interval(num*I, First, Offset)

function Base.:(*)(interval1::Interval{I1, First1, Offset1}, interval2::Interval{I2, First2, Offset2}) where {I1, First1, Offset1, I2, First2, Offset2}
    @assert (First1 == :start && First2 == :start) || (First1 == :end && First2 == :end) "When multiplying two Intervals, both must have the same first argument (:start or :end), otherwise the result is not well defined."
    Interval(I1*I2, First1, Offset1*I2 + Offset2*I1)
end

Base.:(*)(runif::RunIf, interval::Interval) =
    RunIf(schedule_interval(runif) * interval, getcondition(runif), getvars(runif)...)
Base.:(*)(interval::Interval, runif::RunIf) =
    RunIf(interval * schedule_interval(runif), getcondition(runif), getvars(runif)...)
Base.:(*)(runif::RunIf, num::Real) =
    RunIf(schedule_interval(runif) * num, getcondition(runif), getvars(runif)...)
Base.:(*)(num::Real, runif::RunIf) =
    RunIf(num * schedule_interval(runif), getcondition(runif), getvars(runif)...)

function Base.lcm(is::Union{Interval, RunIf}...)
    nums = getinterval.(is)
    return lcm(nums...)
end
