_inspection_branch(idx::Int, total::Int) = idx == total ? "└── " : "├── "
_inspection_stem(idx::Int, total::Int) = idx == total ? "    " : "│   "

function _inspection_print_section(io::IO, title::AbstractString)
    println(io)
    println(io, '\t', title, ":")
end

function _inspection_print_tree_lines(io::IO, lines::Vector{String}; indent = "\t")
    total = length(lines)
    for (idx, line) in enumerate(lines)
        print(io, indent, _inspection_branch(idx, total), line)
        idx == total || println(io)
    end
    println(io)
    return nothing
end

function _inspection_print_empty_tree(io::IO, label::AbstractString)
    _inspection_print_tree_lines(io, [label == "none" ? "<none>" : string(label, ": <none>")])
end

function _inspection_print_entries(io::IO, title::AbstractString, entries::Vector{InspectionEntry})
    _inspection_print_section(io, title)
    if isempty(entries)
        _inspection_print_empty_tree(io, "none")
        return nothing
    end

    lines = map(entries) do entry
        key = isnothing(entry.key) ? "<unkeyed>" : string(entry.key)
        string(key, ": [", entry.kind, "] ", entry.label)
    end
    _inspection_print_tree_lines(io, lines)
    return nothing
end

function _inspection_print_runtime_inputs(io::IO, inputs::Vector{InspectionRuntimeInput})
    _inspection_print_section(io, "Runtime Inputs")
    if isempty(inputs)
        _inspection_print_tree_lines(io, [
            "<no declared metadata>",
            "LoopAlgorithm-level @input metadata is not implemented yet.",
        ])
        return nothing
    end

    lines = map(inputs) do input
        required = input.required ? "required" : "optional"
        default = input.has_default ? string(", default = ", repr(input.default)) : ""
        string(input.name, "::", input.type_label, " (", required, default, ")")
    end
    _inspection_print_tree_lines(io, lines)
    return nothing
end

function _inspection_print_sharing(io::IO, shares::Vector{InspectionShare}, routes::Vector{InspectionRoute})
    _inspection_print_section(io, "Sharing And Routes")
    if isempty(shares) && isempty(routes)
        _inspection_print_empty_tree(io, "none")
        return nothing
    end

    lines = String[]
    for share in shares
        push!(lines, string("share ", share.source, " -> ", share.target))
    end
    for route in routes
        mappings = isempty(route.mappings) ? "<all>" : join((string(p.first, "=>", p.second) for p in route.mappings), ", ")
        transform = isnothing(route.transform) ? "" : string(" transform=", route.transform)
        reverse_transform = isnothing(route.reverse_transform) ? "" : string(" reverse_transform=", route.reverse_transform)
        push!(lines, string("route ", route.source, " -> ", route.target, " (", mappings, ")", transform, reverse_transform))
    end
    _inspection_print_tree_lines(io, lines)
    return nothing
end

function _inspection_print_execution_plan(io::IO, node::InspectionExecutionNode)
    _inspection_print_section(io, "Execution Plan")
    _inspection_print_execution_node(io, node, "\t", true, true)
    return nothing
end

function _inspection_print_execution_node(io::IO, node::InspectionExecutionNode, prefix::String, islast::Bool, isroot::Bool = false)
    if isroot
        println(io, prefix, node.label)
        child_prefix = string(prefix)
    else
        println(io, prefix, islast ? "└── " : "├── ", node.label)
        child_prefix = string(prefix, islast ? "    " : "│   ")
    end

    total = length(node.children)
    for (idx, child) in enumerate(node.children)
        _inspection_print_execution_node(io, child, child_prefix, idx == total)
    end
    return nothing
end

function _inspection_sorted_keys(dict)
    keys_vec = collect(keys(dict))
    sort!(keys_vec; by = string)
    return keys_vec
end

function _inspection_print_requests(io::IO, title::AbstractString, memory)
    _inspection_print_section(io, title)
    if isnothing(memory)
        _inspection_print_empty_tree(io, "not run")
        return nothing
    end

    requests = requested_inputs(memory)
    if isempty(requests)
        _inspection_print_empty_tree(io, "none")
        return nothing
    end

    lines = String[]
    for key in _inspection_sorted_keys(requests)
        push!(lines, string(key, ": ", join(string.(requests[key]), ", ")))
    end
    _inspection_print_tree_lines(io, lines)
    return nothing
end

function _inspection_print_errors(io::IO, title::AbstractString, memory)
    if isnothing(memory) || isempty(memory.errors)
        return nothing
    end

    _inspection_print_section(io, string(title, " Warnings"))
    lines = String[]
    for err in memory.errors
        view = isnothing(err.view) ? "<root>" : string(err.view)
        push!(lines, string(view, ": ", replace(err.error, '\n' => " ")))
    end
    _inspection_print_tree_lines(io, lines)
    return nothing
end

function Base.show(io::IO, report::InspectionReport)
    println(io, "InspectionReport")

    if !isnothing(report.resolve_error)
        _inspection_print_tree_lines(io, [
            "resolved: no",
            string("resolve error: ", report.resolve_error),
        ]; indent = "\t")
        return nothing
    end

    _inspection_print_tree_lines(io, [
        "resolved: yes",
        string("registry entries: ", length(report.registry_entries)),
    ]; indent = "\t")

    _inspection_print_runtime_inputs(io, report.runtime_inputs)
    _inspection_print_entries(io, "States", report.state_entries)
    _inspection_print_entries(io, "Algorithms", report.algorithm_entries)
    _inspection_print_execution_plan(io, report.execution_plan)
    _inspection_print_sharing(io, report.shares, report.routes)
    _inspection_print_requests(io, "Init Reads", report.init_memory)
    _inspection_print_errors(io, "init analysis", report.init_memory)
    _inspection_print_requests(io, "Step Reads", report.step_memory)
    _inspection_print_errors(io, "step analysis", report.step_memory)

    return nothing
end
