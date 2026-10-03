# When does state held in a Ref, a mutable struct or an immutable struct with a Ref field cost something?
# Every container is created by the caller and passed to a @noinline loop function, so it ESCAPES: the compiler
# cannot replace it by registers. Two cases, each at three kernel weights:
#   (1) loop-carried state: x is written and read on every iteration (x = kernel(x, c, i))
#   (2) a parameter read on every iteration and written rarely (every 4096 iterations)
# Compared with a plain local (registers), with the immutable value threaded through the loop (what the package
# does with values in the context), and with a mutable struct that does NOT escape (compiled away). Each case is run
# with four things the loop may also do on every iteration: nothing, store x into an array, call a function the
# compiler can see does not touch the container, and call a function that is handed the state (the value, or the container).
using Printf

const N = 20_000_000

@inline kern(::Val{:tiny}, x, c, i) = x * 0.999 + c
@inline kern(::Val{:small}, x, c, i) = (y = x * 0.999 + c; y = y * 1.0001 - 1e-4 * y * y; y * 0.9999 + 1e-3)
@inline kern(::Val{:medium}, x, c, i) = x * 0.999 + c + 1e-6 * sin(x)

#### what else the loop does on every iteration: nothing, a store into an array, or a call the compiler cannot see through ####
@noinline function opaque(out, i)
    @inbounds out[1] += 1.0
    return nothing
end
# a call that receives the state: by value in the local/threaded cases, the container itself otherwise
@noinline logv(out, x, i) = (@inbounds out[(i & 1023) + 1] = x; nothing)
@inline interfere(::Val{:none}, out, x, i) = nothing
@inline interfere(::Val{:store}, out, x, i) = (@inbounds out[(i & 1023) + 1] = x; nothing)
@inline interfere(::Val{:call}, out, x, i) = opaque(out, i)
@inline interfere(::Val{:callbox}, out, x, i) = logv(out, x, i)

@noinline logb(out, box, i) = (@inbounds out[(i & 1023) + 1] = getx(box); nothing)
@noinline logbc(out, box, i) = (@inbounds out[(i & 1023) + 1] = getc(box); nothing)
@inline interfere_box(I, out, box, i) = interfere(I, out, getx(box), i)
@inline interfere_box(::Val{:callbox}, out, box, i) = logb(out, box, i)
@inline interfere_boxc(I, out, box, x, i) = interfere(I, out, x, i)
@inline interfere_boxc(::Val{:callbox}, out, box, x, i) = logbc(out, box, i)

#### containers ####
mutable struct MutS; x::Float64; c::Float64; end                      # whole struct mutable
struct ImmRef; x::Base.RefValue{Float64}; c::Base.RefValue{Float64}; end          # immutable struct, concrete Ref fields
struct ImmVec; x::Vector{Float64}; c::Vector{Float64}; end                        # immutable struct, one-element vectors
struct ImmVal; x::Float64; c::Float64; end                                        # plain immutable values

getx(b::Base.RefValue) = b[];            setx!(b::Base.RefValue, v) = (b[] = v)
getx(b::MutS) = b.x;                     setx!(b::MutS, v) = (b.x = v)
getx(b::ImmRef) = b.x[];                 setx!(b::ImmRef, v) = (b.x[] = v)
getx(b::ImmVec) = b.x[1];                setx!(b::ImmVec, v) = (b.x[1] = v)
getc(b::MutS) = b.c;                     setc!(b::MutS, v) = (b.c = v)
getc(b::ImmRef) = b.c[];                 setc!(b::ImmRef, v) = (b.c[] = v)
getc(b::ImmVec) = b.c[1];                setc!(b::ImmVec, v) = (b.c[1] = v)
getc(b::Base.RefValue) = b[];            setc!(b::Base.RefValue, v) = (b[] = v)

#### (1) loop-carried state ####
@noinline function state_local(W, I, out, c, n)
    x = 0.0
    for i in 1:n; x = kern(W, x, c, i); interfere(I, out, x, i); end
    return x
end
@noinline function state_box(W, I, out, box, c, n)          # x lives in the container, escaping
    for i in 1:n; setx!(box, kern(W, getx(box), c, i)); interfere_box(I, out, box, i); end
    return getx(box)
end
@noinline function state_threaded(W, I, out, s::ImmVal, n)  # the immutable value is threaded through the loop
    for i in 1:n; s = ImmVal(kern(W, s.x, s.c, i), s.c); interfere(I, out, s.x, i); end
    return s.x
end
@noinline function state_nonescaping(W, I, out, c, n)       # a mutable struct created here and never escaping
    s = MutS(0.0, c)
    for i in 1:n; s.x = kern(W, s.x, s.c, i); interfere(I, out, s.x, i); end
    return s.x
end

#### (2) parameter read every iteration, written every 4096 ####
@inline kernp(W, x, c, i) = kern(W, x, c, i)
@noinline function param_local(W, I, out, c0, n)
    x = 0.0; c = c0
    for i in 1:n
        x = kernp(W, x, c, i); interfere(I, out, x, i)
        (i & 4095 == 0) && (c *= 1.0000001)
    end
    return x
end
@noinline function param_box(W, I, out, box, n)
    x = 0.0
    for i in 1:n
        x = kernp(W, x, getc(box), i); interfere_boxc(I, out, box, x, i)
        (i & 4095 == 0) && setc!(box, getc(box) * 1.0000001)
    end
    return x
end

weights = (:tiny, :small, :medium)
function best_time(f, W)
    f(W)                                           # compile
    best = Inf
    for _ in 1:7
        GC.gc(false); t0 = time_ns(); f(W); best = min(best, (time_ns() - t0) / N)
    end
    return best
end

c0 = 1e-3
const OUT = zeros(1024)
state_cases(I) = [
    ("local variable (registers)",                       W -> state_local(W, I, OUT, c0, N)),
    ("immutable value threaded through the loop",        W -> state_threaded(W, I, OUT, ImmVal(0.0, c0), N)),
    ("mutable struct, not escaping (compiled away)",     W -> state_nonescaping(W, I, OUT, c0, N)),
    ("Base.RefValue{Float64}, escaping",                 W -> state_box(W, I, OUT, Ref(0.0), c0, N)),
    ("whole mutable struct, escaping",                   W -> state_box(W, I, OUT, MutS(0.0, c0), c0, N)),
    ("immutable struct with a RefValue field",           W -> state_box(W, I, OUT, ImmRef(Ref(0.0), Ref(c0)), c0, N)),
    ("immutable struct with a one-element Vector field", W -> state_box(W, I, OUT, ImmVec([0.0], [c0]), c0, N)),
]
param_cases(I) = [
    ("local variable (registers)",                       W -> param_local(W, I, OUT, c0, N)),
    ("Base.RefValue{Float64}, escaping",                 W -> param_box(W, I, OUT, Ref(c0), N)),
    ("whole mutable struct, escaping",                   W -> param_box(W, I, OUT, MutS(0.0, c0), N)),
    ("immutable struct with a RefValue field",           W -> param_box(W, I, OUT, ImmRef(Ref(0.0), Ref(c0)), N)),
    ("immutable struct with a one-element Vector field", W -> param_box(W, I, OUT, ImmVec([0.0], [c0]), N)),
]

function table(title, cases)
    println("\n", title)
    ref = Dict(W => Float64[] for W in weights)
    times = [Dict(W => 0.0 for W in weights) for _ in cases]
    values = [Dict(W => 0.0 for W in weights) for _ in cases]
    for (k, (_, f)) in enumerate(cases), W in weights
        times[k][W] = best_time(w -> f(Val(w)), W); values[k][W] = f(Val(W))
    end
    same = all(values[k][W] == values[1][W] for k in 2:length(cases), W in weights)
    @printf("%-56s %16s %16s %16s %14s %14s %14s\n", "container of the variable", "tiny, ns/iter", "small, ns/iter", "medium, ns/iter", "tiny / local", "small / local", "medium / local")
    for (k, (name, _)) in enumerate(cases)
        @printf("%-56s %16.2f %16.2f %16.2f %14.2f %14.2f %14.2f\n", name, times[k][:tiny], times[k][:small], times[k][:medium],
                times[k][:tiny] / times[1][:tiny], times[k][:small] / times[1][:small], times[k][:medium] / times[1][:medium])
    end
    println("results identical across containers: ", same)
end
descr = Dict(:none => "nothing else in the loop", :store => "the loop also stores x into an array every iteration",
             :call => "the loop also calls a function the compiler cannot see through (it writes to an array)",
             :callbox => "the loop also calls a function that is handed the state (the value, or the container)")
for I in (:none, :store, :call, :callbox)
    table("(1) state written and read on every iteration; " * descr[I], state_cases(Val(I)))
end
for I in (:none, :store, :call, :callbox)
    table("(2) parameter read on every iteration, written every 4096 iterations; " * descr[I], param_cases(Val(I)))
end
