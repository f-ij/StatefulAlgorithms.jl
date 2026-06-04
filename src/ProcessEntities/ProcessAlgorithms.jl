"""
Macro to define a simple ProcessAlgorithm from a function definition.
    This creates a struct of the function name subtype of ProcessAlgorithm,
    with an implicit step! method that calls the function with the provided arguments.    
"""
macro ProcessAlgorithmOld(ex)
    F, args, body = nothing, nothing, nothing
    @capture(ex, function F_(args__) body_ end )
    if isnothing(F)
        @capture(ex, function F_(args__) where W_ body_ end )
    end
    if isnothing(F)
       @capture(ex, function F_(args__) where {W__} body_ end )
    end

    # Get the function name from the expression
    Fname = F
    FFunction = F
    FSymbol = F

    

    ## Handle type annotated functions
    if F isa Expr && F.head == :(::)
        Fname = F.args[1]
        FFunction = Expr(:(::), :f, Fname)
        FSymbol = :f
    end

    splatnames = args
    splatnames = map(name -> name isa Expr && name.head == :(::) ? name.args[1] : name, splatnames)
    splatnames = filter(x -> x != :context, splatnames) # These are the splat args


    typeless_args = map(arg -> arg isa Expr && arg.head == :(::) ? arg.args[1] : arg, args)

    struct_def = quote
        struct $FFunction <: ProcessAlgorithm end
    end

    if length(args) == 0
        struct_def = quote
            struct $FFunction <: ProcessAlgorithm 
                function $FFunction(;_reserved)
                    new()
                end 
            end
        end
    end

    q = quote
            # struct $FFunction <: ProcessAlgorithm end
            $struct_def

            @inline function StatefulAlgorithms.step!(f::$FFunction, context::C) where C <: StatefulAlgorithms.AbstractContext
                $(LineNumberNode(__source__.line, __source__.file))
                (;$(splatnames...)) = context
                @inline $FSymbol($(typeless_args...))
            end

            $ex
        end
    # println(q)
    esc(q)
end

export @ProcessAlgorithm, @NamedProcessAlgorithm
