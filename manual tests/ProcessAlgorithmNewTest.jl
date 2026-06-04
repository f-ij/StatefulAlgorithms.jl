include("_env.jl")

StatefulAlgorithms.@ProcessAlgorithmNew function NewMetric(
    input_signal,
    @managed(scratch::Vector{Float64} = zeros(n)),
    @managed(scale::Float64 = scale0),
    @managed(metric::Float64 = 0.0);
    damp::Float64 = 1.0,
    @init (; n::Int, scale0::Float64 = 1.0)
)
    @inbounds for i in eachindex(input_signal)
        scratch[i] = damp * scale * input_signal[i]
    end
    metric = sum(scratch)
    return (; scratch, scale, metric)
end

signal = [1.0, 2.0, 3.0, 4.0]

boot = NewMetric(signal; damp = 0.5, @init (; n = length(signal), scale0 = 2.0))
piped = NewMetric(signal, copy(boot.scratch), boot.scale, boot.metric; damp = 1.5)
prepared = StatefulAlgorithms.init(NewMetric(), (; n = 4, scale0 = 3.0))
ctx = (; input_signal = signal, scratch = copy(prepared.scratch), scale = prepared.scale, metric = prepared.metric, damp = 2.0)
stepped = StatefulAlgorithms.step!(NewMetric(), ctx)

# This should error if you want to check the mixed-call path manually:
# NewMetric(signal, copy(boot.scratch), boot.scale, boot.metric; @init (; n = 4, scale0 = 2.0))
