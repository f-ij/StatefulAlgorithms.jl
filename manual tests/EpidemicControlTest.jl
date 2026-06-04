include("_env.jl")

# A simple SIR epidemic with composable multi-rate processes:
# - SIR dynamics every day
# - policy updates every 14 days
# - case reporting every 7 days
# - state recording every day
struct SIRStep <: ProcessAlgorithm end
struct NPIPolicy <: ProcessAlgorithm end
struct WeeklyReporter <: ProcessAlgorithm end
struct EpidemicRecorder <: ProcessAlgorithm end

function StatefulAlgorithms.step!(::SIRStep, context)
    (;s, i, r, n, beta, gamma, dt, incidence) = context
    new_infections = min(beta * s * i / n * dt, s)
    recoveries = min(gamma * i * dt, i)

    s = s - new_infections
    i = i + new_infections - recoveries
    r = r + recoveries
    incidence = new_infections
    return (;s, i, r, incidence)
end

function StatefulAlgorithms.init(::SIRStep, _input)
    n = 1_000_000.0
    i0 = 500.0
    r0 = 0.0
    s0 = n - i0 - r0

    beta = 0.28
    gamma = 1.0 / 12.0
    dt = 1.0
    incidence = 0.0
    return (;s = s0, i = i0, r = r0, n, beta, gamma, dt, incidence)
end

function StatefulAlgorithms.step!(::NPIPolicy, context)
    (;i, beta, threshold_on, threshold_off, beta_open, beta_restricted) = context
    if i > threshold_on
        beta = beta_restricted
    elseif i < threshold_off
        beta = beta_open
    end
    return (;beta)
end

function StatefulAlgorithms.init(::NPIPolicy, _input)
    n = 1_000_000.0
    threshold_on = 0.02 * n
    threshold_off = 0.007 * n
    beta_open = 0.28
    beta_restricted = 0.14
    return (;threshold_on, threshold_off, beta_open, beta_restricted)
end

function StatefulAlgorithms.step!(::WeeklyReporter, context)
    (;incidence, report_fraction, reported_cases) = context
    reported_cases = report_fraction * incidence
    return (;reported_cases)
end

function StatefulAlgorithms.init(::WeeklyReporter, _input)
    return (;report_fraction = 0.65, reported_cases = 0.0)
end

function StatefulAlgorithms.step!(::EpidemicRecorder, context)
    (;
    day,
    s,
    i,
    r,
    beta,
    incidence,
    reported_cases,
    days,
    s_hist,
    i_hist,
    r_hist,
    beta_hist,
    incidence_hist,
    reported_hist,
    ) = context

    push!(days, day)
    push!(s_hist, s)
    push!(i_hist, i)
    push!(r_hist, r)
    push!(beta_hist, beta)
    push!(incidence_hist, incidence)
    push!(reported_hist, reported_cases)
    day = day + 1
    return (;day)
end

function StatefulAlgorithms.init(::EpidemicRecorder, input)
    days = Int[]
    s_hist = Float64[]
    i_hist = Float64[]
    r_hist = Float64[]
    beta_hist = Float64[]
    incidence_hist = Float64[]
    reported_hist = Float64[]

    processsizehint!(days, input)
    processsizehint!(s_hist, input)
    processsizehint!(i_hist, input)
    processsizehint!(r_hist, input)
    processsizehint!(beta_hist, input)
    processsizehint!(incidence_hist, input)
    processsizehint!(reported_hist, input)

    return (;day = 0, days, s_hist, i_hist, r_hist, beta_hist, incidence_hist, reported_hist)
end

EpidemicControl = CompositeAlgorithm(
    (SIRStep, NPIPolicy, WeeklyReporter, EpidemicRecorder),
    (1, 14, 7, 1),
    Share(SIRStep, NPIPolicy),
    Route(SIRStep, WeeklyReporter, :incidence),
    Share(SIRStep, EpidemicRecorder),
    Route(WeeklyReporter, EpidemicRecorder, :reported_cases),
)

p = Process(EpidemicControl, lifetime = 365)
run(p)
context = fetch(p)

rec = context[EpidemicRecorder]
sir = context[SIRStep]

peak_idx = argmax(rec.i_hist)
peak_day = rec.days[peak_idx]
peak_i = rec.i_hist[peak_idx]
final_s = rec.s_hist[end]
final_i = rec.i_hist[end]
final_r = rec.r_hist[end]
attack_rate = final_r / sir.n

policy_switches = sum(
    rec.beta_hist[i] != rec.beta_hist[i - 1]
    for i in 2:length(rec.beta_hist)
)

println("EpidemicControl summary")
println("  Population n: ", Int(round(sir.n)))
println("  Peak infectious: ", round(peak_i; digits = 1), " on day ", peak_day)
println("  Final (s, i, r): (",
    round(final_s; digits = 1), ", ",
    round(final_i; digits = 1), ", ",
    round(final_r; digits = 1), ")")
println("  Attack rate r/n: ", round(attack_rate; digits = 4))
println("  Policy switches: ", policy_switches)
println("  Mean daily reported cases: ", round(sum(rec.reported_hist) / length(rec.reported_hist); digits = 2))
