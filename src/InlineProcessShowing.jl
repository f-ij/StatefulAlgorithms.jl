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

    algo_lines = split(sprint(show, getalgo(ip)), '\n')
    print(io, "├── algo = ", algo_lines[1])
    for line in Iterators.drop(algo_lines, 1)
        print(io, "\n", "│   ", line)
    end

    context_lines = split(
        sprint(show, context(ip); context = IOContext(io, :printcontextglobals => false, :limit => get(io, :limit, false), :color => get(io, :color, false))),
        '\n',
    )
    print(io, "\n", "└── context = ", context_lines[1])
    for line in Iterators.drop(context_lines, 1)
        print(io, "\n", "    ", line)
    end

    return nothing
end
