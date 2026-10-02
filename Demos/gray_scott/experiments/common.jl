# Pure helpers shared by both backends' experiments, so the arithmetic is identical and only the
# structure around it (state, scheduling, wiring) differs. Operate on n×n interior views.

using Random, Statistics

coverage(Vi) = Float32(count(>(0.1f0), Vi) / length(Vi))   # fraction of cells with V above 0.1
meanv(Vi) = Float32(sum(Vi) / length(Vi))

function rms_distance(Vi, base)
    s = 0f0
    @inbounds for i in eachindex(Vi, base)
        s += (Vi[i] - base[i])^2
    end
    return sqrt(s / length(Vi))
end

function stamp_disc!(Ui, Vi, x, y, r)                     # a disc of chemical V, as a brush would
    n = size(Ui, 1)
    for j in max(1, floor(Int, y - r)):min(n, ceil(Int, y + r)),
        i in max(1, floor(Int, x - r)):min(n, ceil(Int, x + r))
        (i - x)^2 + (j - y)^2 <= r^2 || continue
        Ui[i, j] = 0.5f0
        Vi[i, j] = 0.25f0
    end
end

# one probe action, given the probe's private state: kick on the first call of a cycle, measure after
function probe_action!(Ui, Vi, base, rng, calls, every, radius, kicks, peak, last, results)
    n = size(Ui, 1)
    calls += 1
    if (calls - 1) % every == 0                            # start of a cycle: close the last one, kick
        kicks > 0 && push!(results, (kicks, peak, last))
        copyto!(base, Vi)
        peak = 0f0
        stamp_disc!(Ui, Vi, 1 + rand(rng, 0:n-1), 1 + rand(rng, 0:n-1), radius)
        kicks += 1
    else                                                   # relaxing: distance from the pre-kick state
        d = rms_distance(Vi, base)
        peak = max(peak, d)
        last = d
    end
    return calls, kicks, peak, last
end

# one controller action: a PI law on coverage, returns the new feed and the new integral
function controller_action(Vi, integral, target, kp, ki)
    err = target - coverage(Vi)
    integral += err
    return clamp(0.037f0 + kp * err + ki * integral, 0.025f0, 0.055f0), integral
end

# E3's schedule: feed ramps lo -> hi over `np` points, then back hi -> lo (2np points in total)
function ramp_value(i, lo, hi, np)
    j = i <= np ? i - 1 : 2np - i
    return lo + (hi - lo) * Float32(j) / Float32(np - 1)
end
