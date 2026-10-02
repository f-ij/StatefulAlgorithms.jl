# Gray-Scott, bespoke: no StatefulAlgorithms. Same control surface as gray_scott_definitions.jl
# (state, set_params!, modify!, pause!, resume!, clear!, reseed!, ...), so gray_scott.jl runs on either.
#
# U, V are stored with a one-cell halo ((n+2)×(n+2)); `interior` is the plain n×n grid.

using Random

interior(A) = @view A[2:end-1, 2:end-1]

# ── kernel (same code as in gray_scott_definitions.jl) ──────────────────────────────────────
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

# ── the simulation: buffers, live controls, and the loop task ───────────────────────────────
mutable struct Sim
    U::Matrix{Float32}; V::Matrix{Float32}; U2::Matrix{Float32}; V2::Matrix{Float32}
    feed::Base.RefValue{Float32}        # live controls: the loop reads these every iteration
    kill::Base.RefValue{Float32}
    pairs::Base.RefValue{Int}           # ping-pong pairs per iteration
    period::Base.RefValue{Float32}      # seconds per iteration; 0 = unthrottled
    steps::Base.RefValue{Int}
    edits::Channel{Function}            # queued f(U, V), run between iterations
    @atomic stop::Bool
    task::Union{Task, Nothing}
end

Sim(n::Int; feed = 0.037f0, kill = 0.060f0) =
    Sim(ones(Float32, n + 2, n + 2), zeros(Float32, n + 2, n + 2),
        ones(Float32, n + 2, n + 2), zeros(Float32, n + 2, n + 2),
        Ref(Float32(feed)), Ref(Float32(kill)), Ref(1), Ref(0f0), Ref(0), Channel{Function}(256),
        false, nothing)

state(s::Sim) = s                       # the buffers and controls are the state

function loop!(s::Sim, niter)
    next = time_ns()
    for _ in 1:niter
        (@atomic s.stop) && break
        while isready(s.edits)
            take!(s.edits)(interior(s.U), interior(s.V))
        end
        f, k = s.feed[], s.kill[]
        for _ in 1:s.pairs[]
            substep!(s.U2, s.V2, s.U, s.V, 1f0, 0.5f0, f, k, 1f0)
            substep!(s.U, s.V, s.U2, s.V2, 1f0, 0.5f0, f, k, 1f0)
        end
        s.steps[] += 2s.pairs[]
        if s.period[] > 0                                        # pacing
            now = time_ns()
            next = max(next, now - 100_000_000) + round(UInt64, 1e9 * s.period[])
            next > now + 200_000 && sleep((next - now) / 1e9)
        end
    end
end

# ── seeding and controls: how a front-end drives it ─────────────────────────────────────────
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

"Build a seeded, started simulation. The buffers and controls are `state(sim)`."
function gray_scott_process(; n = 256, feed = 0.037, kill = 0.060, speed = SPEEDS[5])
    s = Sim(n; feed, kill)
    seed_blobs!(interior(s.U), interior(s.V))
    set_params!(s; speed)
    return resume!(s)
end

"Change feed / kill / speed (substeps per second) while it runs."
function set_params!(s::Sim; feed = nothing, kill = nothing, speed = nothing)
    isnothing(feed) || (s.feed[] = Float32(feed))
    isnothing(kill) || (s.kill[] = Float32(kill))
    if !isnothing(speed)
        s.pairs[] = max(1, round(Int, speed / 2000))             # fast speeds batch substeps per iteration
        s.period[] = speed >= last(SPEEDS) ? 0f0 : Float32(2s.pairs[] / speed)
    end
    return s
end
current_speed(s::Sim) = s.period[] > 0 ? 2s.pairs[] / s.period[] : Inf

isrunning(s::Sim) = !isnothing(s.task) && !istaskdone(s.task)
pause!(s::Sim) = (isrunning(s) && (@atomic(s.stop = true); wait(s.task)); s)
resume!(s::Sim) = (isrunning(s) || (@atomic(s.stop = false); s.task = Threads.@spawn loop!(s, typemax(Int))); s)
Base.close(s::Sim) = pause!(s)

"Run `f(U, V)` on the live n×n fields: at an iteration boundary while running, immediately while paused."
function modify!(f, s::Sim)
    isrunning(s) ? put!(s.edits, f) : f(interior(s.U), interior(s.V))
    return s
end
clear!(s::Sim) = modify!((U, V) -> (fill!(U, 1f0); fill!(V, 0f0)), s)
reseed!(s::Sim) = modify!(seed_blobs!, s)
