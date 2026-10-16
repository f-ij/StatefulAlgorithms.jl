"""
`Callable` printed as its call, `y = f(x; k = 2)`. With `wiring` (its plan slot), an argument
that a wire provides is shown as the wire's source, `owner.field` or `@transform(g, owner.field)`.
"""
function _callable_string(ex::Callable{F, Args, Kwargs, Returns}, wiring = Wiring()) where {F, Args, Kwargs, Returns}
    sources = Dict{Symbol, String}()
    for r in routes(wiring)
        owner = isnothing(getfrom(r)) ? from_match_by(r) : getfrom(r)
        owner_label = owner isa Symbol ? string(owner) : owner isa AbstractIdentifiableAlgo && haskey(owner) ? string(getkey(owner)) : string(owner)
        for (name, alias) in zip(source_fieldnames(r), getaliases(r))
            source = string(owner_label, ".", name isa Tuple ? join(name, ".") : name)
            sources[alias] = isnothing(gettransform(r)) ? source : string("@transform(", gettransform(r), ", ", source, ")")
        end
    end
    shown(item::Symbol) = get(sources, item, string(item))
    shown(item::Splat) = string(get(sources, splatname(item), string(splatname(item))), "...")
    shown(item::ValueRef) = repr(getfield(ex, :values)[_valueref_index(item)])
    shown(item::Tuple) = string(first(item), " = ", shown(last(item)))
    kind, names, types = _returns_parts(Returns)
    returned = kind === :none ? "" : kind === :properties ? "(; " * join((string(first(p), " → ", last(p)) for p in names), ", ") * ") = " :
        join((n isa Splat ? string(splatname(n), "...") : string(n) for n in names), ", ") * " = "
    args = join(map(shown, Args), ", ") * (isempty(Kwargs) ? "" : "; " * join(map(shown, Kwargs), ", "))
    return string("Callable(", returned, getfield(ex, :f), "(", args, "))")
end
Base.show(io::IO, ex::Callable) = print(io, _callable_string(ex))
Base.summary(io::IO, ex::Callable) = show(io, ex)
