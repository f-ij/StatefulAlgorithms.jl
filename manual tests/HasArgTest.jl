using StatefulAlgorithms
struct TestAlgo end

function (::TestAlgo)(args)
    @hasarg if ja
        println(ja)
    end
    @hasarg if nej isa Int
        println(nej)
        nej + 1
        nej + 43
    end
    return
end

p = Process(TestAlgo, nej = 1)
start(p)