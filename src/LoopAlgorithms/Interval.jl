struct Interval{I, First, Offset} end

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

function Base.lcm(is::Interval...)
    nums = getinterval.(is)
    return lcm(nums...)
end