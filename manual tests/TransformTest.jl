include("_env.jl")
struct TransformThis <: ProcessAlgorithm end

function StatefulAlgorithms.init(::TransformThis, input)
    num1 = rand(1:10)
    num2 = rand(1:10)
    println("Initialized with numbers: $num1 and $num2")
    return (;num1, num2)
end

function StatefulAlgorithms.step!(::TransformThis, context)
    (;num1, num2) = context
    num1 = rand(1:10)
    num2 = rand(1:10)
    return (;num1, num2)
end


struct SquareTwoNumbers <: ProcessAlgorithm end

function StatefulAlgorithms.step!(::SquareTwoNumbers, context)
    (;num1, num2) = context
    println("Got numbers: $num1 and $num2, squaring them.")
    num1 = num1^2
    num2 = num2^2
    println("Squared numbers: $num1 and $num2")
    # return (;num1, num2)
end

struct SquareOneNumber <: ProcessAlgorithm end
function StatefulAlgorithms.step!(::SquareOneNumber, context)
    (;targetnum) = context
    println("SquareOneNumber got number: $targetnum, squaring it.")
    targetnum = targetnum^2
    println("SquareOneNumber squared number: $targetnum")
    return
end

comp = CompositeAlgorithm(TransformThis, SquareTwoNumbers, SquareOneNumber, (1, 1, 1),
    Route(TransformThis => SquareTwoNumbers, :num1, :num2),
    Route(TransformThis => SquareOneNumber, (:num1, :num2) => :targetnum, transform = (num1, num2) -> num1 + num2)
    )

p = Process(comp, lifetime = 3)
run(p)
