@generated function algo_and_interval_iterator(cla)
    numalgos = StatefulAlgorithms.numalgos(cla)
    exprs = (Expr(:tuple, :(getindex(getalgos(cla), $i)), :(interval(cla, $i))) for i in 1:numalgos)
    return Expr(:tuple, exprs...)
end

const LoopAlgorithmTypes = Union{AbstractLoopAlgorithm, Type{<:AbstractLoopAlgorithm}}