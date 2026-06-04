mutable struct AlgoBranch
    const f::ProcessAlgorithm
    const linearidx::Int
    const branchpath
    stepidx::Int
    repeat_accum::Int
end

AlgoBranch(f::ProcessAlgorithm, linearidx) = AlgoBranch(f, linearidx, branchpath(f, linearidx), 1, 1)
export AlgoBranch, walk!, branchpath

branchpath(a::AlgoBranch) = a.branchpath


repeats(::Any) = 1
repeats(::Any, idx) = 1

function thisnode(a::AlgoBranch)
    if a.stepidx == 1
        return a.f
    end
    enterbranches(a.f, branchpath(a)[1:a.stepidx-1]...)
end

branchidx(a::AlgoBranch) = branchpath(a)[a.stepidx]

function getrepeat(a::AlgoBranch)
    if a.stepidx == length(branchpath(a)) + 1
        return 1
    end
    repeats(thisnode(a), branchidx(a))
end

function walk!(ab::AlgoBranch)
    if ab.stepidx == length(branchpath(ab)) + 1
        return nothing
    end
    node = thisnode(ab)
    ab.stepidx += 1
    return node
end


function algo_num_executions(pa::ProcessAlgorithm, linearidx)
    ab = AlgoBranch(pa, linearidx)
    # println("AlgoBranch: ", ab)
    rpts = getrepeat(ab)
    walk!(ab)
     
    return rpts * _algo_num_executions(ab)
end

function _algo_num_executions(ab::AlgoBranch)
    if !is_decomposable(thisnode(ab))
        return 1
    end
    rpts = getrepeat(ab)
    walk!(ab)
    
    return rpts * _algo_num_executions(ab)
end

"""
Get the number of times an algorithm will be repeated
Can be a fraction for Composite algorithms (I think..) TODO: Check this
"""
getrepeats(f::ProcessAlgorithm, linearidx) = Float64(algo_num_executions(f, linearidx))::Float64
