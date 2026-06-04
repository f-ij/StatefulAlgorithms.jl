struct Integrator{T, id} <: ProcessAlgorithm end

Integrator(T = Float64; name::Union{Symbol, UUID} = uuid4()) = Integrator{T, name}()

function init(::Integrator{T}, context::C) where {T, C}
    total = @inline get(context, :initialvalue, zero(T))
    stepsize = @inline get(context, :stepsize, one(T))

    total = convert(T, total)
    stepsize = convert(T, stepsize)

    (;total, stepsize)
end

function step!(::Integrator{T}, context::C) where {T, C}
    (;total, Δvalue, stepsize) = context
    Δvalue = convert(T, Δvalue)
    total += Δvalue * stepsize
    return (;total)
end