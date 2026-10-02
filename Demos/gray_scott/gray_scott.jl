# Interactive Gray-Scott window. This file is only the interface: it has no simulation and does not
# know which backend is behind it. A backend is any script that defines this control surface:
#
#   gray_scott_process(), state(sim) with .V/.feed/.kill/.steps, interior, set_params!, current_speed,
#   modify!, clear!, reseed!, pause!, resume!, isrunning, close, SPEEDS
#
# Run it through an entry point, which loads a backend and then this file:
#
#   julia -t auto --project=Demos/gray_scott Demos/gray_scott/run_sa.jl        # StatefulAlgorithms
#   julia -t auto --project=Demos/gray_scott Demos/gray_scott/run_bespoke.jl   # hand-written
#
# Painting is this file's job: see `paint!`.
#
#   drag on the canvas      paint         right-drag / shift-drag   erase
#   click or drag the map   change regime sliders / presets         tune live
#   Pause                   freezes the simulation; painting still works, Resume continues

using GLMakie


# ── (feed, kill) plane: named regimes and the line beyond which no pattern survives ─────────
const REGIMES = [
    (name = "Mitosis",      feed = 0.0367, kill = 0.0649),
    (name = "Coral",        feed = 0.0545, kill = 0.0620),
    (name = "Fingerprints", feed = 0.0290, kill = 0.0570),
    (name = "Worms",        feed = 0.0620, kill = 0.0609),
    (name = "Solitons",     feed = 0.0300, kill = 0.0620),
    (name = "Chaos",        feed = 0.0260, kill = 0.0510),
]
pattern_limit(f) = sqrt(f) / 2 - f        # saddle-node line of the equations: above it no pattern survives

# ── look ────────────────────────────────────────────────────────────────────────────────────
const BG     = RGBf(0.035, 0.040, 0.063)
const PANEL  = RGBf(0.075, 0.085, 0.125)
const HOVER  = RGBf(0.14, 0.15, 0.22)
const FG     = RGBf(0.86, 0.88, 0.95)
const DIM    = RGBf(0.50, 0.54, 0.65)
const ACCENT = RGBf(1.00, 0.66, 0.30)
const INK    = cgrad([
    RGBf(0.02, 0.02, 0.07), RGBf(0.10, 0.07, 0.34), RGBf(0.36, 0.10, 0.52),
    RGBf(0.80, 0.22, 0.46), RGBf(1.00, 0.55, 0.30), RGBf(1.00, 0.88, 0.60), RGBf(1.0, 0.99, 0.93),
])

const FEED_RANGE = (0.010, 0.080)
const KILL_RANGE = (0.040, 0.072)

panel_button(pos, label) = Button(pos; label, fontsize = 14, buttoncolor = PANEL,
    buttoncolor_hover = HOVER, labelcolor = FG, cornerradius = 7, padding = (4, 4, 7, 7),
    width = Relative(1))

speed_label(r) = r >= last(SPEEDS) ? "max" : string(round(r / 1000; digits = 2)) * "k/s"

"Left/right-drag on the axis would zoom and pan by default; the canvas wants those for the brush."
disable_navigation!(ax) = foreach(n -> deregister_interaction!(ax, n),
    (:rectanglezoom, :dragpan, :scrollzoom, :limitreset))

# ── brush: the UI's notion of painting, built on the simulation's generic `modify!` ─────────────
"Stamp (or erase) a disc of chemical V centred on grid position (x, y)."
function paint!(sim, x, y, r; erase = false)
    modify!(sim) do U, V
        n = size(U, 1)
        for j in max(1, floor(Int, y - r)):min(n, ceil(Int, y + r)),
            i in max(1, floor(Int, x - r)):min(n, ceil(Int, x + r))
            (i - x)^2 + (j - y)^2 <= r^2 || continue
            U[i, j] = erase ? 1f0 : 0.5f0
            V[i, j] = erase ? 0f0 : 0.25f0
        end
    end
end

# ── canvas: draws V directly, turns the mouse into paint! ────────────────────────────
# The chemistry relaxes within a frame or two, so a stamped blob would barely be visible. The canvas
# therefore draws its own fading trail of the brush strokes, independent of what the simulation does.
const TRAIL_SECONDS = 0.7

function add_canvas!(fig, pos, sim, brush)
    n = size(state(sim).V, 1) - 2
    ax = Axis(pos; aspect = DataAspect(), backgroundcolor = BG)
    hidedecorations!(ax); hidespines!(ax); disable_navigation!(ax)
    limits!(ax, 0.5, n + 0.5, 0.5, n + 0.5)

    image = Observable(interior(state(sim).V))      # the hot array itself, no copy
    heatmap!(ax, image; colormap = INK, colorrange = (0f0, 0.36f0), interpolate = true)

    strokes = NamedTuple{(:p, :r, :erase, :t), Tuple{Point2f, Float32, Bool, Float64}}[]
    trail_p, trail_r, trail_c = Observable(Point2f[]), Observable(Float32[]), Observable(RGBAf[])
    scatter!(ax, trail_p; markersize = trail_r, color = trail_c, markerspace = :data)

    ring = Observable(Point2f[])                      # brush outline under the cursor
    lines!(ax, ring; color = (:white, 0.55), linewidth = 1.5)

    on(events(fig).mouseposition) do _
        if !is_mouseinside(ax)
            isempty(ring[]) || (ring[] = Point2f[])
            return
        end
        x, y = mouseposition(ax)
        r = brush[]
        ring[] = [Point2f(x + r * cos(t), y + r * sin(t)) for t in range(0, 2π; length = 40)]
        erasing = ispressed(fig, Mouse.right) || (ispressed(fig, Mouse.left) && ispressed(fig, Keyboard.left_shift))
        if erasing || ispressed(fig, Mouse.left)
            paint!(sim, x, y, r; erase = erasing)
            push!(strokes, (; p = Point2f(x, y), r = Float32(r), erase = erasing, t = time()))
        end
    end

    # called by the display loop: show the latest frame, fade the trail
    function refresh!()
        notify(image)
        now = time()
        filter!(s -> now - s.t < TRAIL_SECONDS, strokes)
        trail_p[] = [s.p for s in strokes]
        trail_r[] = [2s.r for s in strokes]                   # markersize is a diameter in data units
        trail_c[] = [RGBAf(s.erase ? RGBf(0.25, 0.55, 1.0) : RGBf(1, 1, 1), 0.35 * (1 - (now - s.t) / TRAIL_SECONDS))
                     for s in strokes]
        return nothing
    end
    return (; refresh!)
end

# ── regime map: the (feed, kill) plane. `regime` is the single source of truth ──────────────
function add_regime_map!(fig, pos, regime)
    fmin, fmax = FEED_RANGE
    kmin, kmax = KILL_RANGE
    ax = Axis(pos; backgroundcolor = PANEL, aspect = 1.3,
        xlabel = "feed  f", ylabel = "kill  k", xlabelcolor = DIM, ylabelcolor = DIM,
        xlabelsize = 13, ylabelsize = 13, xticklabelcolor = DIM, yticklabelcolor = DIM,
        xticklabelsize = 11, yticklabelsize = 11, xtickcolor = DIM, ytickcolor = DIM,
        topspinevisible = false, rightspinevisible = false,
        leftspinecolor = DIM, bottomspinecolor = DIM,
        xgridcolor = (:white, 0.05), ygridcolor = (:white, 0.05),
        xticks = 0.01:0.02:0.08, yticks = 0.04:0.01:0.07)
    limits!(ax, fmin, fmax, kmin, kmax)
    disable_navigation!(ax)

    fs = range(fmin, fmax; length = 200)
    edge = pattern_limit.(fs)
    band!(ax, fs, edge, fill(kmax, length(fs)); color = (:black, 0.35))
    lines!(ax, fs, edge; color = (ACCENT, 0.6), linewidth = 1.5, linestyle = :dash)
    text!(ax, 0.0775, 0.0715; text = "no pattern", color = (DIM, 0.9), fontsize = 11, align = (:right, :top))
    scatter!(ax, [r.feed for r in REGIMES], [r.kill for r in REGIMES]; color = (:white, 0.5), markersize = 6)
    for r in REGIMES
        text!(ax, r.feed, r.kill; text = r.name, color = (FG, 0.7), fontsize = 10,
              offset = (6, 5), align = (:left, :bottom))
    end
    scatter!(ax, regime; color = ACCENT, markersize = 13, strokecolor = :white, strokewidth = 1.5)

    pick() = let (f, k) = mouseposition(ax)
        regime[] = Point2f(clamp(f, fmin, fmax), clamp(k, kmin, kmax))
    end
    on(events(fig).mousebutton) do ev
        ev.button == Mouse.left && ev.action == Mouse.press && is_mouseinside(ax) && pick()
    end
    on(events(fig).mouseposition) do _
        ispressed(fig, Mouse.left) && is_mouseinside(ax) && pick()
    end
    return ax
end

# ── controls: sliders, presets, run buttons ─────────────────────────────────────────────────
function add_controls!(pos, sim, regime, brush)
    fmin, fmax = FEED_RANGE
    kmin, kmax = KILL_RANGE
    grid = pos[1, 1] = GridLayout()

    sg = SliderGrid(grid[1, 1],
        (label = "feed",  range = fmin:0.0001:fmax, format = x -> string(round(x; digits = 4)), startvalue = regime[][1]),
        (label = "kill",  range = kmin:0.0001:kmax, format = x -> string(round(x; digits = 4)), startvalue = regime[][2]),
        (label = "speed", range = 1:length(SPEEDS), format = i -> speed_label(SPEEDS[i]), startvalue = findfirst(>=(current_speed(sim)), SPEEDS)),
        (label = "brush", range = 2:24, format = x -> string(x) * " px", startvalue = brush[]);
        width = 360)
    foreach(s -> (s.color_active[] = ACCENT; s.color_active_dimmed[] = ACCENT), sg.sliders)
    foreach(l -> (l.color = DIM), sg.labels)
    foreach(l -> (l.color = FG), sg.valuelabels)
    fslider, kslider, speedslider, brushslider = sg.sliders

    # feed/kill: `regime` drives the simulation and the sliders; the sliders write back to `regime`
    syncing = Ref(false)
    on(regime; update = true) do p
        set_params!(sim; feed = p[1], kill = p[2])
        syncing[] = true
        set_close_to!(fslider, p[1]); set_close_to!(kslider, p[2])
        syncing[] = false
    end
    on(v -> syncing[] || (regime[] = Point2f(v, regime[][2])), fslider.value)
    on(v -> syncing[] || (regime[] = Point2f(regime[][1], v)), kslider.value)
    on(i -> set_params!(sim; speed = SPEEDS[i]), speedslider.value)
    on(v -> (brush[] = v), brushslider.value)

    # presets: a regime plus fresh seeds (spots cannot grow into stripes, so starting fresh is kinder)
    presets = grid[2, 1] = GridLayout()
    colgap!(presets, 8); rowgap!(presets, 8)
    for (i, r) in enumerate(REGIMES)
        b = panel_button(presets[(i - 1) ÷ 3 + 1, (i - 1) % 3 + 1], r.name)
        on(_ -> (regime[] = Point2f(r.feed, r.kill); reseed!(sim)), b.clicks)
    end

    actions = grid[3, 1] = GridLayout()
    colgap!(actions, 8)
    playbtn  = panel_button(actions[1, 1], "Pause")
    reseedbtn = panel_button(actions[1, 2], "Reseed")
    clearbtn = panel_button(actions[1, 3], "Clear")
    on(playbtn.clicks) do _
        if isrunning(sim)
            pause!(sim); playbtn.label = "Resume"
        else
            resume!(sim); playbtn.label = "Pause"
        end
    end
    on(_ -> reseed!(sim), reseedbtn.clicks)
    on(_ -> clear!(sim), clearbtn.clicks)

    rowgap!(grid, 1, 12); rowgap!(grid, 2, 10)
    return grid
end

# ── display loop ────────────────────────────────────────────────────────────────────────────
function start_display!(canvas, status, sim)
    last = Ref((time(), state(sim).steps[]))
    return Timer(0.2; interval = 1 / 40) do _
        canvas.refresh!()
        t0, s0 = last[]
        t1 = time()
        t1 - t0 < 0.5 && return
        s1 = state(sim).steps[]
        last[] = (t1, s1)
        died = maximum(interior(state(sim).V)) < 0.02f0
        status[] = string(isrunning(sim) ? "running" : "paused", "  ·  ",
                          round(Int, (s1 - s0) / (t1 - t0) / 1000), "k steps/s  ·  t = ", s1 ÷ 1000, "k",
                          died ? "\npattern died out: press Reseed" : "")
    end
end

# ── assembly ────────────────────────────────────────────────────────────────────────────────
function build_ui(sim)
    fig = Figure(size = (1240, 800), backgroundcolor = BG, figure_padding = 22)
    brush = Observable(7)
    regime = Observable(Point2f(state(sim).feed[], state(sim).kill[]))
    status = Observable("")

    canvas = add_canvas!(fig, fig[1, 1], sim, brush)

    side = fig[1, 2] = GridLayout(; tellheight = false)
    colsize!(fig.layout, 2, Fixed(360)); colgap!(fig.layout, 26)
    Label(side[1, 1], "Gray–Scott"; fontsize = 34, color = FG, halign = :left, font = :bold)
    Label(side[2, 1], "reaction–diffusion, stepped by StatefulAlgorithms.jl"; fontsize = 13, color = DIM, halign = :left)
    add_regime_map!(fig, side[3, 1], regime)
    add_controls!(side[4, 1], sim, regime, brush)
    Label(side[5, 1], "drag  paint      right-drag  erase\nclick the map to jump between regimes";
          fontsize = 12, color = DIM, halign = :left, justification = :left)
    Label(side[6, 1], status; fontsize = 13, color = ACCENT, halign = :left, justification = :left,
          tellheight = false, valign = :top)
    rowgap!(side, 1, 4); rowgap!(side, 2, 16); rowgap!(side, 3, 8); rowgap!(side, 4, 12); rowgap!(side, 5, 10)

    ticker = start_display!(canvas, status, sim)
    return (; fig, ticker)
end

function main()
    Threads.nthreads() == 1 && @warn "Running on one thread; start Julia with `-t auto` for a faster simulation."
    sim = gray_scott_process()
    ui = build_ui(sim)
    wait(display(ui.fig))
    close(ui.ticker)
    close(sim)
    return nothing
end

