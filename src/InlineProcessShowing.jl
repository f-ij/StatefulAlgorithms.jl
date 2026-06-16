@inline function _inline_process_mode_label(ip::InlineProcess)
    if isthreaded(ip)
        return :threaded
    elseif isasync(ip)
        return :async
    else
        return :sync
    end
end

@inline function _inline_process_algo_summary(ip::InlineProcess)
    return sprint(summary, getalgo(ip))
end

function Base.summary(io::IO, ip::InlineProcess)
    print(io, "InlineProcess(", _inline_process_algo_summary(ip), ")")
end

function Base.show(io::IO, ip::InlineProcess)
    print(
        io,
        "InlineProcess(",
        _inline_process_algo_summary(ip),
        ", lifetime=",
        lifetime(ip),
        ", mode=",
        _inline_process_mode_label(ip),
        ", loopidx=",
        loopint(ip),
        ")",
    )
end

function Base.show(io::IO, ::MIME"text/plain", ip::InlineProcess)
    println(io, "InlineProcess")
    println(io, "├── mode = ", _inline_process_mode_label(ip))
    println(io, "├── lifetime = ", lifetime(ip))
    println(io, "├── loopidx = ", loopint(ip))

    algo_lines = _process_nested_show_lines(io, getalgo(ip))
    _print_process_nested_field(io, "├── ", "│   ", :algo, algo_lines)

    context_lines = _process_context_show_lines(io, context(ip))
    _print_process_nested_field(io, "└── ", "    ", :context, context_lines)

    return nothing
end
