function Base.show(io::IO, tca::ThreadedCompositeAlgorithm)
    println(io, "BarrieredCompositeAlgorithm")
    funcs = getalgos(tca)
    if isempty(funcs)
        print(io, "└── (empty)")
        return
    end
    _intervals = StatefulAlgorithms.intervals(tca)
    limit = get(io, :limit, false)
    show_ctx = IOContext(io, :limit => limit, :color => get(io, :color, false))
    total = length(funcs)
    for (idx, thisfunc) in enumerate(funcs)
        interval = _intervals[idx]
        func_str = repr(thisfunc; context = show_ctx)
        lines = split(func_str, '\n')
        suffix = " (every " * string(interval) * " time(s))"
        _print_tree_lines(io, idx, total, lines; suffix)
        if idx < total
            print(io, "\n")
        end
    end
end

function Base.summary(io::IO, tca::ThreadedCompositeAlgorithm)
    funcs = getalgos(tca)
    if isempty(funcs)
        print(io, "BarrieredCompositeAlgorithm (empty)")
        return
    end
    _intervals = StatefulAlgorithms.intervals(tca)
    println(io, "BarrieredCompositeAlgorithm")
    total = length(funcs)
    for (idx, f) in enumerate(funcs)
        interval = _intervals[idx]
        suffix = " (every " * string(interval) * " time(s))"
        lines = split(_algo_label(f), '\n')
        _print_tree_lines(io, idx, total, lines; suffix)
        if idx < total
            print(io, "\n")
        end
    end
end

function Base.show(io::IO, tcaT::Type{<:ThreadedCompositeAlgorithm})
    dt = Base.unwrap_unionall(tcaT)
    if length(dt.parameters) == 0
        print(io, "BarrieredCompositeAlgorithm")
        return
    end
    ft = dt.parameters[1]
    if ft isa TypeVar
        print(io, "BarrieredCompositeAlgorithm")
        return
    end
    labels = _composite_algo_type_labels(ft.parameters)
    print(io, "BarrieredCompositeAlgorithm(", join(labels, ", "), ")")
end
