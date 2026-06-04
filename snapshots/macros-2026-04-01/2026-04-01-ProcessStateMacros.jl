"""
Macro to define a ProcessState from a function definition.
This creates a struct subtype of ProcessState with a init method.
"""
macro ProcessState(ex)
    F, args, body = nothing, nothing, nothing
    @capture(ex, function F_(args__) body_ end)
    if isnothing(F)
        @capture(ex, function F_(args__) where W_ body_ end)
    end
    if isnothing(F)
        @capture(ex, function F_(args__) where {W__} body_ end)
    end

    Fname = F
    FFunction = F
    FSymbol = F

    if F isa Expr && F.head == :(::)
        Fname = F.args[1]
        FFunction = Expr(:(::), :s, Fname)
        FSymbol = :s
    end

    splatnames = args
    splatnames = map(name -> name isa Expr && name.head == :(::) ? name.args[1] : name, splatnames)
    splatnames = filter(x -> x != :context, splatnames)

    typeless_args = map(arg -> arg isa Expr && arg.head == :(::) ? arg.args[1] : arg, args)

    q = quote
            struct $FFunction <: ProcessState end

            @inline function Processes.init(s::$FFunction, context::C) where C <: Processes.AbstractContext
                (;$(splatnames...)) = context
                return @inline $FSymbol($(typeless_args...))
            end

            $ex
        end
    esc(q)
end

export @ProcessState
