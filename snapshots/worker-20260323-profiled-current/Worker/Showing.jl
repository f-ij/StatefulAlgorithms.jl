export workergraph, showworkergraph, workerspawncode, showworkerspawncode
export daggergraph, showdaggergraph, daggerspawncode, showdaggerspawncode

struct WorkerGraphView{DCA, C}
    algo::DCA
end

const DaggerGraphView = WorkerGraphView

@inline workergraph(dca::DCA, ::Type{C}) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext} = WorkerGraphView{DCA, C}(dca)
@inline workergraph(dca::DCA, context::C) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext} = WorkerGraphView{DCA, C}(dca)

function workergraph(p::Process)
    algo = getalgo(p.taskdata)
    algo isa DaggerCompositeAlgorithm || error("`workergraph(p)` requires `p` to use a WorkerCompositeAlgorithm.")
    context = p.context
    context isa ProcessContext || error("`workergraph(p)` requires `p.context` to be a ProcessContext.")
    return workergraph(algo, typeof(context))
end

@inline showworkergraph(io::IO, dca::DCA, ::Type{C}) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext} = show(io, workergraph(dca, C))
@inline showworkergraph(io::IO, dca::DCA, context::C) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext} = show(io, workergraph(dca, context))
@inline showworkergraph(io::IO, p::Process) = show(io, workergraph(p))

@inline workerspawncode(dca::DaggerCompositeAlgorithm) = _worker_graph_results_expr(typeof(dca); pretty = true)
@inline workerspawncode(dcaT::Type{<:DaggerCompositeAlgorithm}) = _worker_graph_results_expr(dcaT; pretty = true)

function showworkerspawncode(io::IO, dca::DaggerCompositeAlgorithm)
    print(io, workerspawncode(dca))
end

function showworkerspawncode(io::IO, dcaT::Type{<:DaggerCompositeAlgorithm})
    print(io, workerspawncode(dcaT))
end

@inline daggergraph(args...) = workergraph(args...)
@inline showdaggergraph(args...) = showworkergraph(args...)
@inline daggerspawncode(args...) = workerspawncode(args...)
@inline showdaggerspawncode(args...) = showworkerspawncode(args...)

@inline function _worker_graph_edge_labels(sv)
    srcs = subvarcontextnames(sv)
    dsts = localnames(sv)
    return join(ntuple(i -> string(srcs[i], " => ", dsts[i]), length(srcs)), ", ")
end

function _worker_graph_debug(::Type{DCA}, ::Type{C}) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext}
    n = numalgos(DCA)
    child_names = ntuple(i -> getkey(getalgotype(DCA, i)), n)
    parents = [Int[] for _ in 1:n]
    children = [Int[] for _ in 1:n]
    edge_labels = Dict{Tuple{Int, Int}, Vector{String}}()
    specs = _worker_graph_specs(DCA)

    for idx in 1:n
        child_name = child_names[idx]
        child_name isa Symbol || continue

        subcontext_t = subcontext_type(C, child_name)
        for sharedvar_t in getsharedvars_types(subcontext_t)
            parent_name = get_fromname(sharedvar_t)
            parent_name isa Symbol || continue

            parent_idx = findfirst(==(parent_name), child_names)
            isnothing(parent_idx) && continue
            parent_idx == idx && continue

            if !(parent_idx in parents[idx])
                push!(parents[idx], parent_idx)
            end
            if !(idx in children[parent_idx])
                push!(children[parent_idx], idx)
            end

            label_key = (parent_idx, idx)
            labels = get!(edge_labels, label_key, String[])
            push!(labels, _worker_graph_edge_labels(sharedvar_t))
        end
    end

    topo = map(first, specs)
    return (; child_names, parents, children, edge_labels, topo)
end

@inline function _worker_graph_node_label(dca::DaggerCompositeAlgorithm, idx::Int)
    return _algo_label(getalgo(dca, idx))
end

@inline function _worker_graph_parent_label(dca::DaggerCompositeAlgorithm, idx::Int, labels::Vector{String})
    label = _worker_graph_node_label(dca, idx)
    isempty(labels) && return string("[", idx, "] ", label)
    return string("[", idx, "] ", label, " via ", join(labels, " | "))
end

@inline function _worker_graph_node_flags(parents::Vector{Int}, children::Vector{Int})
    flags = String[]
    isempty(parents) && push!(flags, "root")
    length(parents) > 1 && push!(flags, "join")
    isempty(children) && push!(flags, "leaf")
    length(children) > 1 && push!(flags, "branch")
    return isempty(flags) ? "" : " [" * join(flags, ", ") * "]"
end

function Base.show(io::IO, graph::WorkerGraphView{DCA, C}) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext}
    dca = graph.algo
    info = _worker_graph_debug(DCA, C)
    n = numalgos(DCA)
    _intervals = Processes.intervals(dca)

    println(io, "WorkerGraph")
    n == 0 && return print(io, "└── (empty)")

    for idx in 1:n
        parents = info.parents[idx]
        children = info.children[idx]
        node_lines = String[]
        push!(node_lines, string("[", idx, "] ", _worker_graph_node_label(dca, idx), " (every ", _intervals[idx], " time(s))", _worker_graph_node_flags(parents, children)))

        if isempty(parents)
            push!(node_lines, "parents: none")
        else
            parent_labels = String[]
            for parent in parents
                labels = get(info.edge_labels, (parent, idx), String[])
                push!(parent_labels, _worker_graph_parent_label(dca, parent, labels))
            end
            push!(node_lines, "parents: " * join(parent_labels, ", "))
        end

        if isempty(children)
            push!(node_lines, "children: none")
        else
            child_labels = ntuple(i -> string("[", children[i], "] ", _worker_graph_node_label(dca, children[i])), length(children))
            push!(node_lines, "children: " * join(child_labels, ", "))
        end

        topo_idx = findfirst(==(idx), info.topo)
        !isnothing(topo_idx) && push!(node_lines, "topological position: " * string(topo_idx))

        _print_tree_lines(io, idx, n, node_lines)
        idx < n && print(io, "\n")
    end
end

function Base.summary(io::IO, graph::WorkerGraphView{DCA, C}) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext}
    info = _worker_graph_debug(DCA, C)
    print(io, "WorkerGraph(", length(info.topo), " node(s))")
end

function Base.show(io::IO, dca::DaggerCompositeAlgorithm)
    println(io, "WorkerCompositeAlgorithm")
    funcs = dca.funcs
    if isempty(funcs)
        print(io, "└── (empty)")
        return
    end
    _intervals = Processes.intervals(dca)
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

function Base.summary(io::IO, dca::DaggerCompositeAlgorithm)
    funcs = dca.funcs
    if isempty(funcs)
        print(io, "WorkerCompositeAlgorithm (empty)")
        return
    end
    _intervals = Processes.intervals(dca)
    println(io, "WorkerCompositeAlgorithm")
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

function Base.show(io::IO, dcaT::Type{<:DaggerCompositeAlgorithm})
    dt = Base.unwrap_unionall(dcaT)
    if length(dt.parameters) == 0
        print(io, "WorkerCompositeAlgorithm")
        return
    end
    ft = dt.parameters[1]
    if ft isa TypeVar
        print(io, "WorkerCompositeAlgorithm")
        return
    end
    labels = _composite_algo_type_labels(ft.parameters)
    print(io, "WorkerCompositeAlgorithm(", join(labels, ", "), ")")
end
