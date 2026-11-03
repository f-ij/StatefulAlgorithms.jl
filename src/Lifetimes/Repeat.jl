#=
`Repeat(n)`: `n` repeats; the count is the loop's bound. No condition of its own: the default stop check.
=#

struct Repeat <: RepeatLifetime
    repeats::Int
end
