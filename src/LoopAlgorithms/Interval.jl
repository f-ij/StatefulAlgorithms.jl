export Interval, RunIf

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
RunIf(interval::Interval, cond::Function, vars...) = RunIf{vars, typeof(cond), typeof(interval)}(cond, interval)
RunIf(interval::Real, cond::Function, vars...) = RunIf(Interval(interval), cond, vars...)

@inline getcondition(runif::RunIf) = getfield(runif, :cond)
@inline getinterval(runif::RunIf) = getinterval(getfield(runif, :interval))
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

"""Return whether a composite schedule entry should run on this tick."""
@inline should_run_schedule(interval::Interval, loopidx::Int, context) = @inline divides(loopidx, interval)

@inline function should_run_schedule(runif::RunIf{Vars}, loopidx::Int, context) where {Vars}
    if !(@inline divides(loopidx, runif))
        return false
    end
    if isempty(Vars)
        return @inline getcondition(runif)()
    end
    return @inline getcondition(runif)(getindex(context, Vars...))
end

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

Base.:(*)(runif::RunIf{Vars}, interval::Interval) where {Vars} =
    RunIf(schedule_interval(runif) * interval, getcondition(runif), Vars...)
Base.:(*)(interval::Interval, runif::RunIf{Vars}) where {Vars} =
    RunIf(interval * schedule_interval(runif), getcondition(runif), Vars...)
Base.:(*)(runif::RunIf{Vars}, num::Real) where {Vars} =
    RunIf(schedule_interval(runif) * num, getcondition(runif), Vars...)
Base.:(*)(num::Real, runif::RunIf{Vars}) where {Vars} =
    RunIf(num * schedule_interval(runif), getcondition(runif), Vars...)

function Base.lcm(is::Union{Interval, RunIf}...)
    nums = getinterval.(is)
    return lcm(nums...)
end
