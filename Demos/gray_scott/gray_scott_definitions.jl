# Gray-Scott as StatefulAlgorithms: the steps and the process. No UI in here.
#
#   Edit       runs queued edit functions f(U, V) on the live fields      every iteration
#   GrayScott  advances the chemistry                                     every iteration
#   Pace       sleeps so the loop runs at the requested speed             every iteration
#
# U, V are stored with a one-cell halo ((n+2)×(n+2)); `interior` is the plain n×n grid. The halo is
# refreshed from the opposite edges once per substep, so the sweep needs no per-cell wrap logic.

using StatefulAlgorithms
using Random

interior(A) = @view A[2:end-1, 2:end-1]

# ── kernel ──────────────────────────────────────────────────────────────────────────────────
@inline function wrap_halo!(A)
    n = size(A, 1) - 2
    @inbounds begin
        for i in 2:n+1
            A[i, 1] = A[i, n+1]; A[i, n+2] = A[i, 2]
        end
        for j in 1:n+2
            A[1, j] = A[n+1, j]; A[n+2, j] = A[2, j]
        end
    end
end

# One explicit Euler step on a periodic grid (9-point Laplacian).
function substep!(Uo, Vo, Ui, Vi, Du, Dv, f, k, dt)
    n = size(Ui, 1) - 2
    wrap_halo!(Ui); wrap_halo!(Vi)
    a, b, fk = 0.2f0, 0.05f0, f + k
    nth = Threads.nthreads()
    Threads.@threads :static for t in 1:nth
        j0 = 2 + ((t - 1) * n) ÷ nth
        j1 = 1 + (t * n) ÷ nth
        @inbounds for j in j0:j1
            @simd for i in 2:n+1
                u = Ui[i, j]
                v = Vi[i, j]
                lapu = a * (Ui[i-1, j] + Ui[i+1, j] + Ui[i, j-1] + Ui[i, j+1]) +
                       b * (Ui[i-1, j-1] + Ui[i+1, j-1] + Ui[i-1, j+1] + Ui[i+1, j+1]) - u
                lapv = a * (Vi[i-1, j] + Vi[i+1, j] + Vi[i, j-1] + Vi[i, j+1]) +
                       b * (Vi[i-1, j-1] + Vi[i+1, j-1] + Vi[i-1, j+1] + Vi[i+1, j+1]) - v
                uvv = u * v * v
                Uo[i, j] = u + dt * (Du * lapu - uvv + f * (1f0 - u))
                Vo[i, j] = v + dt * (Dv * lapv + uvv - fk * v)
            end
        end
    end
end

# ── steps ───────────────────────────────────────────────────────────────────────────────────
# Callers queue functions f(U, V); this runs them between two physics steps. Editing the fields from
# another thread while the physics ping-pongs through them would be overwritten.
@StepAlgorithm function Edit(edits, U, V)
    while isready(edits)
        take!(edits)(interior(U), interior(V))
    end
    return (;)
end

# `pairs` ping-pong pairs per step (U,V → U2,V2 → U,V), so U,V always hold the current state.
@StepAlgorithm begin
    @config Du::Float32 = 1f0
    @config Dv::Float32 = 0.5f0
    @config dt::Float32 = 1f0

    function GrayScott(U, V, U2, V2, feed, kill, pairs, steps)
        for _ in 1:pairs
            substep!(U2, V2, U, V, Du, Dv, feed, kill, dt)
            substep!(U, V, U2, V2, Du, Dv, feed, kill, dt)
        end
        steps[] += 2pairs
        return (;)
    end
end

# Holds the iteration at `period` seconds. Unthrottled, the loop runs far faster than anyone can watch.
@StepAlgorithm function Pace(period, @managed(next = Ref(time_ns())))
    period > 0 || return (;)
    now = time_ns()
    next[] = max(next[], now - 100_000_000) + round(UInt64, 1e9 * period)   # never catch up > 0.1 s
    wait = Int(next[]) - Int(now)
    wait > 200_000 && sleep(wait / 1e9)
    return (;)
end

# ── process ─────────────────────────────────────────────────────────────────────────────────
function gray_scott_algorithm(n, feed, kill)
    return @CompositeAlgorithm begin
        @state sim begin
            feed = feed
            kill = kill
            pairs = 1                          # ping-pong pairs per iteration
            period = 0f0                       # seconds per iteration, see `Pace`
            edits = Channel{Function}(256)     # queued f(U, V), run by `Edit`
            U = ones(Float32, n + 2, n + 2)
            V = zeros(Float32, n + 2, n + 2)
            U2 = ones(Float32, n + 2, n + 2)   # scratch partners for the ping-pong
            V2 = zeros(Float32, n + 2, n + 2)
            steps = Ref(0)
        end

        Edit(edits, U, V)
        GrayScott(U, V, U2, V2, feed, kill, pairs, steps)
        Pace(period)
    end
end

# ── seeding and controls: how a front-end drives a running process ──────────────────────────
function seed_blobs!(U, V; nblobs = 8)
    fill!(U, 1f0); fill!(V, 0f0)
    n = size(U, 1)
    r = max(n ÷ 32, 3)
    for _ in 1:nblobs
        cx, cy = rand((r + 1):(n - r - 1), 2)
        for j in (cy - r):(cy + r), i in (cx - r):(cx + r)
            U[i, j] = 0.5f0 + 0.02f0 * randn(Float32)
            V[i, j] = 0.25f0 + 0.02f0 * randn(Float32)
        end
    end
end

"Selectable speeds in substeps per second. The last is effectively unthrottled."
const SPEEDS = 250 .* 2 .^ (0:7)

"Build a seeded, started process. Its live state is `state(process)`; the window reads `interior(state(process).V)` directly."
function gray_scott_process(; n = 256, feed = 0.037, kill = 0.060, speed = SPEEDS[5])
    p = Process(resolve(gray_scott_algorithm(n, Float32(feed), Float32(kill))),
                Interactive(:sim, :feed, :kill, :pairs, :period))    # live control surface. TODO(TODO.md, API readability): target `:sim`, then the fields to wrap
    seed_blobs!(interior(state(p).U), interior(state(p).V))
    set_params!(p; speed)
    run(p)
    return p
end

state(p::Process) = context(p).sim

"Change feed / kill / speed (substeps per second) while the process runs."
function set_params!(p::Process; feed = nothing, kill = nothing, speed = nothing)
    st = state(p)
    isnothing(feed) || (st.feed[] = Float32(feed))
    isnothing(kill) || (st.kill[] = Float32(kill))
    if !isnothing(speed)
        st.pairs[] = max(1, round(Int, speed / 2000))        # fast speeds batch substeps per iteration
        st.period[] = speed >= last(SPEEDS) ? 0f0 : Float32(2st.pairs[] / speed)
    end
    return p
end
current_speed(p::Process) = state(p).period[] > 0 ? 2state(p).pairs[] / state(p).period[] : Inf

"Pause and wait until the loop has actually stopped (`pause` alone only raises a flag)."
pause!(p::Process) = (isrunning(p) && (pause(p); wait(p)); p)
resume!(p::Process) = (isrunning(p) || run(p); p)

"Run `f(U, V)` on the live n×n fields: at a step boundary while running, immediately while paused."
function modify!(f, p::Process)
    st = state(p)
    if isrunning(p)
        put!(st.edits, f)
    else
        f(interior(st.U), interior(st.V))
    end
    return p
end
clear!(p::Process) = modify!((U, V) -> (fill!(U, 1f0); fill!(V, 0f0)), p)
reseed!(p::Process) = modify!(seed_blobs!, p)
