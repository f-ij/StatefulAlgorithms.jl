using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using BenchmarkTools
using InteractiveUtils
using StatefulAlgorithms

struct IncBy{T}
    value::T
end

struct ScaleBy{T}
    value::T
end

struct ShiftLeft
    bits::Int
end

@inline apply_op(acc, op::IncBy) = acc + op.value
@inline apply_op(acc, op::ScaleBy) = acc * op.value
@inline apply_op(acc, op::ShiftLeft) = acc * (one(acc) + one(acc))^op.bits

const HOMOGENEOUS_ARGS = (IncBy(1), IncBy(2), IncBy(3), IncBy(4), IncBy(5), IncBy(6))
const HETEROGENEOUS_ARGS = (IncBy(1), ScaleBy(3), IncBy(2.5), ScaleBy(4.0), ShiftLeft(1))

old_unrollreplace(args) = StatefulAlgorithms.unrollreplace_splat(apply_op, 1, args...)
new_unrollreplace(args) = StatefulAlgorithms.unrollreplace(apply_op, 1, args)

function run_case(label, args)
    old_result = old_unrollreplace(args)
    new_result = new_unrollreplace(args)
    @assert old_result == new_result

    println()
    println(label)
    println("-" ^ length(label))
    println("result: ", old_result, " :: ", typeof(old_result))
    println("old unrollreplace, splatted args:")
    display(@benchmark old_unrollreplace($args))
    println("new unrollreplace, tuple arg:")
    display(@benchmark new_unrollreplace($args))
end

function show_inference(label, args)
    println()
    println(label, " inference")
    println("-" ^ (length(label) + 10))
    println("old_unrollreplace:")
    code_warntype(stdout, old_unrollreplace, Tuple{typeof(args)})
    println()
    println("new_unrollreplace:")
    code_warntype(stdout, new_unrollreplace, Tuple{typeof(args)})
end

run_case("Homogeneous typed arguments", HOMOGENEOUS_ARGS)
run_case("Heterogeneous typed arguments", HETEROGENEOUS_ARGS)

show_inference("Homogeneous", HOMOGENEOUS_ARGS)
show_inference("Heterogeneous", HETEROGENEOUS_ARGS)
