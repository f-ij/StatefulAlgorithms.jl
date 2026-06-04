struct Interactive{T} <: ProcessAlgorithm end
"""
Take value from channel, and overwrite target with it
"""
function StatefulAlgorithms.step!(::Interactive{T}, context) where T
    (;channel, target) = context
    target = take!(channel)
    return (;target)
end
function StatefulAlgorithms.cleanup(::Interactive{T}, context) where T
    (;channel) = context
    close(channel)
    return (;)
end

Base.put!(I::Interactive{T}, value::T) where T = put!(I.channel, value)