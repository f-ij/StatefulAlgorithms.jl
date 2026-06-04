include("_env.jl")

plusnums(a, b) = a + b

@ProcessAlgorithm function addstate(@managed(num); @inputs((;num)))
    num = num + 1
    (;num)
end

comp = @CompositeAlgorithm begin

    @state mystate begin
        x
        sum = 0.0
    end
    num = addstate()
    sum = plusnums(x,num)
end


p = Process(comp, Input(:mystate, x = 1.0), Input(addstate, num = 1.0), repeat = 2)
run(p)

c = fetch(p)