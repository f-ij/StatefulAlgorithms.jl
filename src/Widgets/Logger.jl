"""
Log a variable
"""
struct Logger{T, Name} <: ProcessAlgorithm end

Logger(T; name = uuid4()) = Logger{T, name}()
Logger(; name = uuid4()) = Logger{Any, name}()

function StatefulAlgorithms.init(::Logger{T}, context::C) where {T, C}
    log = Vector{T}()
    processsizehint!(log, context)
    return (;log)
end
function pushderef!(vec::V, val::TVal) where {V<:AbstractVector, TVal}
    if val isa Ref
        push!(vec, val[])
    else
        push!(vec, val)
    end
end

function StatefulAlgorithms.step!(::Logger{T}, context::C) where {T, C}
    (;log, value) = context
    pushderef!(log, value)
    return (;)
end
