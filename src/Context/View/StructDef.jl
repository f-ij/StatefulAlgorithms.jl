
"""
    InjectedValues()

Where an injected value is stored: the values given to a view directly (`inject`), held by the view itself
(`SubContextView.injected`), not by a run's context.
"""
struct InjectedValues end

"""
    VarLocation(storage, field, func = nothing, reversefunc = nothing)

Where a name a view sees is stored: `field` (or a tuple of fields, read through `func`) in `storage`, which is
- `StatePartition{namespace}()`: a field of a namespace's state (the view's own, or another's through a route or share);
- `RuntimePartition{name}()`: a runtime value (declared local, input, captured or subcontext return);
- `InjectedValues()`: a value given to the view directly.
`reversefunc` maps a written value back onto the fields.
"""
struct VarLocation{Storage, field, func, reversefunc} end
# Not specialized, to save compile time: views are built for many namespaces, and each partition is its own type.
VarLocation(@nospecialize(storage::Union{Partition, InjectedValues}), field::Union{Tuple, Symbol}, @nospecialize(func) = nothing, @nospecialize(reversefunc) = nothing) =
    VarLocation{typeof(storage), field, func, reversefunc}()

"""
    RedirectedVar(varlocation)

Persistent context marker for a state field whose algorithm-facing value is
backed by another `VarLocation`.
"""
struct RedirectedVar{T<:VarLocation}
    varlocation::T
end

"""Return the read transform carried by a `VarLocation`."""
@inline getfunc(vl::Union{VarLocation{S, field, func}, Type{<:VarLocation{S, field, func}}}) where {S, field, func} = func

"""Return the writeback transform carried by a `VarLocation`."""
@inline getreversefunc(vl::Union{VarLocation{S, field, func, reversefunc}, Type{<:VarLocation{S, field, func, reversefunc}}}) where {S, field, func, reversefunc} = reversefunc
"""Return the subcontext name of the partition a `VarLocation` is stored in."""
@inline get_subcontextname(vl::Union{VarLocation{P}, Type{<:VarLocation{P}}}) where {P<:Partition} = partition_name(P)
@inline location_fieldname(vl::Union{VarLocation{S, field}, Type{<:VarLocation{S, field}}}) where {S, field} = field

"""
For variable names :a, :b, :c
    create the expression :(func(:a, :b, :c)) where func is the function to apply to the variable names
"""
@inline function funcexpr(vl::Union{VL, Type{<:VL}}, 
        varnames...) where VL <: VarLocation
            func = getfunc(vl) 
            if isnothing(func)
                if length(varnames) == 1 # If no func, can only have one var
                    return :($(varnames[1]))
                else 
                    error("Error: VarLocation: $vl with a function must have exactly one variable name, got $(varnames)")
                end
            end
            return Expr(:call, func, varnames...)
end

@inline function getvar_expressions_and_varnames(vl::Union{VL, Type{<:VL}}) where VL <: VarLocation
    varnames = location_fieldname(vl)
    numvars = varnames isa Tuple ? length(varnames) : 1
    varnames = varnames isa Tuple ? varnames : (varnames,)
    assign_symbols = ntuple(i -> gensym(:var), numvars)
    partition = context_partition(vl)
    return [:($(assign_symbols[i]) = @inline _read_partition($partition, sct, Val($(QuoteNode(varnames[i])))))
        for i in 1:numvars], assign_symbols
end

"""
What one algorithm (`instance`, in namespace `SubName`) sees of a context bundle (`LoopContext` while stepping,
`InitContext` while initializing): its state, the variables wired to it, and, from the bundle, inputs and the names
of the scope it is in (declared locals, captured returns). `injected` holds values given to it directly.
"""
struct SubContextView{B<:ContextBundle, SubName, T, NT, VarAliases, Shares, Routes} <: AbstractContext
    bundle::B
    instance::T # ScopedInstance for which the view is created
    injected::NT

    function SubContextView{B, SubName, T, NT}(bundle::B, instance::T; inject::NT = (;)) where {B<:ContextBundle, SubName, T, NT}
        new{B, SubName, T, typeof(inject), varaliases(instance), (), ()}(bundle, instance, inject)
    end

    function SubContextView{B, SubName, T, NT, VarAliases, Shares, Routes}(bundle::B, instance::T, inject::NT = (;)) where {B<:ContextBundle, SubName, T, NT, VarAliases, Shares, Routes}
        new{B, SubName, T, typeof(inject), VarAliases, Shares, Routes}(bundle, instance, inject)
    end
end
