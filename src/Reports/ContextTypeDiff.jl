struct ContextTypeDiffResult{B,A,Ad,C,R}
    before::B
    after::A
    added::Ad
    changed::C
    removed::R
end

function _ntype_snapshot(nt::Type{<:NamedTuple})
    names = fieldnames(nt)
    return (; (name => fieldtype(nt, name) for name in names)...)
end

function _scope_type_snapshot(scope_type::Type)
    if scope_type <: SubContext
        return _ntype_snapshot(getdatatype(scope_type))
    elseif scope_type <: NamedTuple
        return _ntype_snapshot(scope_type)
    else
        return (; _type = scope_type)
    end
end

function _context_type_snapshot(::Type{<:ProcessContext{D}}) where {D}
    names = fieldnames(D)
    return (; (name => _scope_type_snapshot(fieldtype(D, name)) for name in names)...)
end

_context_type_snapshot(pc::ProcessContext) = _context_type_snapshot(typeof(pc))

function _scope_type_diff(before::NamedTuple, after::NamedTuple)
    added = Pair{Symbol, Any}[]
    changed = Pair{Symbol, Any}[]
    removed = Pair{Symbol, Any}[]

    before_names = propertynames(before)
    after_names = propertynames(after)

    for name in after_names
        if !haskey(before, name)
            push!(added, name => getproperty(after, name))
        elseif getproperty(before, name) != getproperty(after, name)
            push!(changed, name => (; from = getproperty(before, name), to = getproperty(after, name)))
        end
    end

    for name in before_names
        if !haskey(after, name)
            push!(removed, name => getproperty(before, name))
        end
    end

    return (; added = (; added...), changed = (; changed...), removed = (; removed...))
end

function ContextTypeDiff(before::Type{<:ProcessContext}, after::Type{<:ProcessContext})
    before_snapshot = _context_type_snapshot(before)
    after_snapshot = _context_type_snapshot(after)

    added = Pair{Symbol, Any}[]
    changed = Pair{Symbol, Any}[]
    removed = Pair{Symbol, Any}[]

    before_names = propertynames(before_snapshot)
    after_names = propertynames(after_snapshot)

    for scope_name in after_names
        if !haskey(before_snapshot, scope_name)
            push!(added, scope_name => getproperty(after_snapshot, scope_name))
            continue
        end

        scope_diff = _scope_type_diff(getproperty(before_snapshot, scope_name), getproperty(after_snapshot, scope_name))
        if !isempty(scope_diff.added)
            push!(added, scope_name => scope_diff.added)
        end
        if !isempty(scope_diff.changed)
            push!(changed, scope_name => scope_diff.changed)
        end
        if !isempty(scope_diff.removed)
            push!(removed, scope_name => scope_diff.removed)
        end
    end

    for scope_name in before_names
        if !haskey(after_snapshot, scope_name)
            push!(removed, scope_name => getproperty(before_snapshot, scope_name))
        end
    end

    return ContextTypeDiffResult(
        before_snapshot,
        after_snapshot,
        (; added...),
        (; changed...),
        (; removed...),
    )
end

ContextTypeDiff(before::ProcessContext, after::ProcessContext) = ContextTypeDiff(typeof(before), typeof(after))

function _show_context_type_snapshot(io::IO, title::AbstractString, snapshot::NamedTuple)
    println(io, title)
    for scope_name in propertynames(snapshot)
        scope_snapshot = getproperty(snapshot, scope_name)
        if isempty(scope_snapshot)
            println(io, "  ", scope_name, ": <empty>")
            continue
        end
        println(io, "  ", scope_name, ":")
        for var_name in propertynames(scope_snapshot)
            println(io, "    ", var_name, " :: ", getproperty(scope_snapshot, var_name))
        end
    end
end

function _show_context_type_changes(io::IO, title::AbstractString, changes::NamedTuple)
    println(io, title)
    if isempty(changes)
        println(io, "  <none>")
        return nothing
    end

    for scope_name in propertynames(changes)
        scope_changes = getproperty(changes, scope_name)
        println(io, "  ", scope_name, ":")
        for var_name in propertynames(scope_changes)
            val = getproperty(scope_changes, var_name)
            if val isa NamedTuple && haskey(val, :from) && haskey(val, :to)
                println(io, "    ", var_name, " :: ", val.from, " => ", val.to)
            else
                println(io, "    ", var_name, " :: ", val)
            end
        end
    end
    return nothing
end

function Base.show(io::IO, diff::ContextTypeDiffResult)
    println(io, "ContextTypeDiff")
    _show_context_type_snapshot(io, "before:", diff.before)
    _show_context_type_snapshot(io, "after:", diff.after)
    _show_context_type_changes(io, "added:", diff.added)
    _show_context_type_changes(io, "changed:", diff.changed)
    _show_context_type_changes(io, "removed:", diff.removed)
    return nothing
end
