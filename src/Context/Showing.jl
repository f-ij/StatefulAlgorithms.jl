

########################
### DISPLAY ###
########################

@inline _is_input_like(x) = x isa Input || x isa Override
@inline _printcontextglobals(io::IO) = get(io, :printcontextglobals, true)

function _format_inputs_tuple(t::Tuple)
    isempty(t) && return "Inputs: ∅"
    items = String[]
    for it in t
        if _is_input_like(it)
            push!(items, string(get_target_name(it), " ", get_vars(it)))
        else
            push!(items, sprint(summary, it))
        end
    end
    return "Inputs: " * join(items, ", ")
end

@inline function _context_display_columns(io::IO)
    _, cols = displaysize(io)
    return cols > 0 ? cols : 80
end

function _context_wrap_chunks(text::AbstractString, width::Int)
    width = max(width, 8)
    chars = collect(text)
    isempty(chars) && return [""]

    chunks = String[]
    i = 1
    n = length(chars)
    while i <= n
        used = 0
        j = i
        last_space = 0
        while j <= n
            char_width = Base.Unicode.textwidth(chars[j])
            if used + char_width > width
                break
            end
            used += char_width
            isspace(chars[j]) && (last_space = j)
            j += 1
        end

        if j > n
            push!(chunks, String(chars[i:n]))
            break
        elseif last_space >= i
            push!(chunks, rstrip(String(chars[i:last_space-1])))
            i = last_space + 1
            while i <= n && isspace(chars[i])
                i += 1
            end
        else
            push!(chunks, String(chars[i:j-1]))
            i = j
        end
    end

    return isempty(chunks) ? [""] : chunks
end

function _print_wrapped_prefixed(io::IO, text::AbstractString, first_prefix::AbstractString, continuation_prefix::AbstractString)
    raw_lines = split(text, '\n')
    cols = _context_display_columns(io)
    first_width = cols - Base.Unicode.textwidth(first_prefix)
    continuation_width = cols - Base.Unicode.textwidth(continuation_prefix)

    first_chunks = _context_wrap_chunks(first(raw_lines), first_width)
    println(io, first_prefix, first(first_chunks))
    for chunk in Iterators.drop(first_chunks, 1)
        println(io, continuation_prefix, chunk)
    end

    for raw in Iterators.drop(raw_lines, 1)
        chunks = _context_wrap_chunks(raw, continuation_width)
        for chunk in chunks
            println(io, continuation_prefix, chunk)
        end
    end
    return nothing
end

function _subcontext_var_lines(sc::SubContext; io::IO = stdout)
    lines = String[]
    show_ctx = IOContext(io, :limit => get(io, :limit, false), :color => get(io, :color, false))
    data = getdata(sc)
    data_names = propertynames(data)
    if isempty(data_names)
        push!(lines, "vars: ∅")
    else
        for name in data_names
            val = getproperty(data, name)
            if val isa Tuple && all(_is_input_like, val)
                push!(lines, string(name, " = ", _format_inputs_tuple(val)))
            else
                push!(lines, string(name, " = ", sprint(summary, val; context = show_ctx)))
            end
        end
    end
    return lines
end

function _subcontext_var_lines(sc::NamedTuple; io::IO = stdout)
    lines = String[]
    show_ctx = IOContext(io, :limit => get(io, :limit, false), :color => get(io, :color, false))
    data_names = propertynames(sc)
    if isempty(data_names)
        push!(lines, "vars: ∅")
    else
        for name in data_names
            val = getproperty(sc, name)
            if val isa Tuple && all(_is_input_like, val)
                push!(lines, string(name, " = ", _format_inputs_tuple(val)))
            else
                push!(lines, string(name, " = ", sprint(summary, val; context = show_ctx)))
            end
        end
    end
    return lines
end

function Base.show(io::IO, sc::SubContext)
    println(io, "SubContext ", getkey(sc))
    for line in _subcontext_var_lines(sc; io)
        println(io, "  ", line)
    end
    return nothing
end

#=
function Base.show(io::IO, pc::ProcessContext)
    println(io, "ProcessContext")
    subs = get_subcontexts(pc)
    names = collect(propertynames(subs))
    last_idx = length(names)
    for (idx, name) in enumerate(names)
        sc = getproperty(subs, name)
        branch = idx == last_idx ? "└── " : "├── "
        stem = idx == last_idx ? "    " : "│   "
        println(io, branch, "[", idx, "]: ", name)

        var_lines = _subcontext_var_lines(sc; io)
        var_last_idx = length(var_lines)
        for (var_idx, line) in enumerate(var_lines)
            var_branch = var_idx == var_last_idx ? " └── " : " ├── "
            var_stem = var_idx == var_last_idx ? "    " : "│   "
            split_lines = split(line, '\n')
            println(io, stem, var_branch, split_lines[1])
            for continuation in Iterators.drop(split_lines, 1)
                println(io, stem, var_stem, lstrip(continuation))
            end
        end
    end
    return nothing
end
=#

function Base.show(io::IO, pc::ProcessContext)
    println(io, "ProcessContext")
    show_ctx = IOContext(
        io,
        :limit => get(io, :limit, false),
        :color => get(io, :color, false),
        :printcontextglobals => _printcontextglobals(io),
    )
    subs = get_subcontexts(pc)
    names = collect(propertynames(subs))
    if !_printcontextglobals(io)
        filter!(name -> name != :globals, names)
    end
    last_idx = length(names)

    for (idx, name) in enumerate(names)
        sc = getproperty(subs, name)
        branch = idx == last_idx ? "└── " : "├── "
        stem = idx == last_idx ? "    " : "│   "
        println(io, branch, "[", idx, "]: ", name)

        var_lines = _subcontext_var_lines(sc; io = show_ctx)
        var_last_idx = length(var_lines)
        for (var_idx, line) in enumerate(var_lines)
            var_branch = var_idx == var_last_idx ? " └── " : " ├── "
            continuation_stem = var_idx == var_last_idx ? "    " : "│   "
            _print_wrapped_prefixed(io, line, stem * var_branch, stem * continuation_stem)
        end
    end
    return nothing
end
