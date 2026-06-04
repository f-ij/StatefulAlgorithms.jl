export setrepeats, setintervals, setinterval, setrepeats

function setrepeats(r::Routine{F, Repeats, NS}, newrepeats) where {F, Repeats, NS}
    setfield(r, :repeats, newrepeats)
end

function setintervals(r::Routine{F, Intervals, NS}, newintervals) where {F, Intervals, NS}
    setfield(r, :repeats, newintervals)
end

function setinterval(r::CompositeAlgorithm{F, Intervals, NS}, idx::Int, newinterval::Interval) where {F, Intervals, NS}
    updated_intervals = setindex(intervals(r), newinterval, idx)
    setfield(r, :intervals, updated_intervals)
end

setinterval(r::CompositeAlgorithm{F, Intervals, NS}, idx::Int, newinterval::Number) where {F, Intervals, NS} = setinterval(r, idx, Interval(newinterval))

function setrepeats(r::CompositeAlgorithm{F, Repeats, NS}, idx::Int, newrepeats) where {F, Repeats, NS}
    updated_repeats = setindex(intervals(r), newrepeats, idx)
    setfield(r, :intervals, updated_repeats)
end
