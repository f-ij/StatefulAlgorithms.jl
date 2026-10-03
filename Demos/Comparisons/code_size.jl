# Code size by tokens, not lines: the number of source tokens (identifiers, literals, operators, keywords, brackets)
# with whitespace, newlines and comments ignored, counted with Julia's own tokenizer. Unlike a line count it does not depend
# on whether statements are packed onto one line with `;` or `->`. Characters without whitespace are shown as a second measure.
using Base.JuliaSyntax: tokenize, kind, is_whitespace, untokenize

function tokens(code::AbstractString)
    n = 0
    for t in tokenize(code)
        is_whitespace(kind(t)) || (n += 1)
    end
    return n
end
nonspace_chars(code) = count(c -> !isspace(c), join(filter(l -> !startswith(strip(l), "#"), split(code, "\n")), "\n"))

"""Text of the top-level block that starts at the first line matching `pattern` and ends at the first `end` in column 0."""
function block(path, pattern)
    lines = readlines(path)
    i = findfirst(l -> occursin(pattern, l), lines)
    i === nothing && error("no match for $pattern in $path")
    j = findnext(l -> l == "end", lines, i)
    return join(lines[i:j], "\n")
end

size_of(code) = (tokens = tokens(code), chars = nonspace_chars(code), lines = count(l -> !isempty(strip(l)) && !startswith(strip(l), "#"), split(code, "\n")))

function row(label, code)
    s = size_of(code)
    println(rpad(label, 62), lpad(s.tokens, 8), lpad(s.chars, 8), lpad(s.lines, 8))
end
function header(title)
    println("\n", title)
    println(rpad("what the user writes", 62), lpad("tokens", 8), lpad("chars", 8), lpad("lines", 8))
end

root = joinpath(@__DIR__)
d = joinpath(root, "driven"); s = joinpath(root, "stages")

header("driven chain, full experiment (sine drive, checkpoints, three modifiers): the front end in frontend.jl")
pk = block(joinpath(d, "frontend.jl"), "function package_experiment")
sc = block(joinpath(d, "frontend.jl"), "function sciml_experiment")
row("package: composition, setup and run", pk)
comps = [("SineDrive", joinpath(d, "framework.jl"), "@StepAlgorithm function SineDrive("),
         ("DampingRamp", joinpath(d, "modifiers.jl"), "@StepAlgorithm function DampingRamp("),
         ("ToleranceSchedule", joinpath(d, "modifiers.jl"), "@StepAlgorithm function ToleranceSchedule("),
         ("StateKick", joinpath(d, "modifiers.jl"), "@StepAlgorithm function StateKick("),
         ("Checkpointer", joinpath(d, "framework.jl"), "@StepAlgorithm function Checkpointer(")]
for (n, p, pat) in comps; row("package: component " * n, block(p, pat)); end
row("package: composition + the five components", join([pk; [block(p, pat) for (_, p, pat) in comps]], "\n"))
row("package: the DSL line that adds one component (NoiseKick)", "NoiseKick(u = integ.u, nacc = integ.nacc, stale = integ.stale)")
row("SciML: callbacks, setup and solve", sc)

header("multi-stage experiment (stages/), after the damping change: what the user writes")
fe = block(joinpath(s, "framework.jl"), "function framework_experiment")
row("package: the experiment (stages, core, routine)", fe)
cs = [("Polarization", "@StepAlgorithm function Polarization("), ("FieldLoop", "@StepAlgorithm function FieldLoop(")]
for (n, pat) in cs; row("package: component " * n, block(joinpath(s, "framework.jl"), pat)); end
function begin_block(path, name)       # the `@StepAlgorithm begin ... end` form with @config lines
    lines = readlines(path)
    i = findfirst(l -> occursin("function $name(", l), lines)
    a = findprev(l -> startswith(l, "@StepAlgorithm begin"), lines, i)
    b = findnext(l -> l == "end", lines, i)
    return join(lines[a:b], "\n")
end
ramp = begin_block(joinpath(s, "framework.jl"), "FieldRamp"); gamma = begin_block(joinpath(s, "framework.jl"), "GammaRamp")
row("package: component FieldRamp", ramp); row("package: component GammaRamp", gamma)
row("package: total, without the integrator", join([fe, block(joinpath(s, "framework.jl"), "@StepAlgorithm function Polarization("),
    block(joinpath(s, "framework.jl"), "@StepAlgorithm function FieldLoop("), ramp, gamma], "\n"))
println("(not counted: the integrator ChainFixed, ", tokens(block(joinpath(s, "framework.jl"), "@StepAlgorithm function ChainFixed(")), " tokens, since SciML provides its solver)")
row("SciML: sciml_setup + sciml_go! (callbacks, setup, solve, closing fix)", join([block(joinpath(s, "sciml.jl"), "function sciml_setup"), block(joinpath(s, "sciml.jl"), "function sciml_go!")], "\n"))
