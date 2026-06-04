export GeneralState, InlineState

"""
General-purpose `ProcessState` that acts as an initialization scheme.

Core init semantics:
- `Fields`: subcontext variables initialized by this state.
- `Required`: fields that must already be present in the init context.
- `DefaultValuesBuilder`: the closure type used to produce optional defaults.

Construction diagnostics:
- `ExplicitlySharedFields`: field names whose overlap was documented with DSL
  syntax such as `@bind` or `@merge`.
- `DiagnosticFieldPaths`: display paths such as `(:f, :buffers)` used only to
  make overlap warnings readable.

Only `Fields`, `Required`, and `default_values_builder` determine initialized
values. The diagnostic parameters do not participate in `init`; they exist
because registry construction merges `GeneralState` values and needs enough
context to warn about accidental DSL state sharing before the final init scheme
is used.
"""
struct GeneralState{Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths} <: ProcessState
    default_values_builder::DefaultValuesBuilder
end


# TODO Maybe make it match with any general state where one has a subset of the fields of the other? 
"""
General states match by key for now
"""
match_by(ia::Union{IdentifiableAlgo{<:GeneralState}, Type{<:IdentifiableAlgo{<:GeneralState}}}) = ValMatcher(getkey(ia))

const InlineState = GeneralState

@inline function _general_state_default_diagnostic_paths(::Val{Fields}) where {Fields}
    return ntuple(i -> (Fields[i],), length(Fields))
end

@inline function GeneralState(default_values_builder::DefaultValuesBuilder, ::Val{Fields}, ::Val{Required}) where {DefaultValuesBuilder, Fields, Required}
    diagnostic_paths = _general_state_default_diagnostic_paths(Val{Fields}())
    GeneralState{Fields, Required, DefaultValuesBuilder, (), diagnostic_paths}(default_values_builder)
end

@inline function GeneralState(default_values_builder::DefaultValuesBuilder, ::Val{Fields}, ::Val{Required}, ::Val{ExplicitlySharedFields}, ::Val{DiagnosticFieldPaths}) where {DefaultValuesBuilder, Fields, Required, ExplicitlySharedFields, DiagnosticFieldPaths}
    GeneralState{Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths}(default_values_builder)
end

StatefulAlgorithms.registry_allowmerge(::Union{GeneralState, Type{<:GeneralState}}) = true

@inline general_state_fields(::GeneralState{Fields}) where {Fields} = Fields
@inline general_state_required_fields(::GeneralState{Fields, Required}) where {Fields, Required} = Required
@inline general_state_explicitly_shared_fields(::GeneralState{Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields}) where {Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields} = ExplicitlySharedFields
@inline general_state_diagnostic_field_paths(::GeneralState{Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths}) where {Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths} = DiagnosticFieldPaths

function _general_state_signature(state::GeneralState)
    parts = String[]
    required = general_state_required_fields(state)

    for field in general_state_fields(state)
        if field in required
            push!(parts, string(field))
        else
            push!(parts, string(field, " = <default>"))
        end
    end

    return string("GeneralState(", join(parts, ", "), ")")
end

Base.summary(io::IO, state::GeneralState) = print(io, _general_state_signature(state))
Base.show(io::IO, state::GeneralState) = print(io, _general_state_signature(state))

"""Return a copy of `state` with these fields recorded as intentional overlaps.

This is construction metadata for DSL-created states. It does not add routes and
does not affect `init`; it only suppresses accidental-sharing warnings for the
named fields during registry merge.
"""
function mark_general_state_fields_explicitly_shared(state::S, fields::Tuple{Vararg{Symbol}}) where {Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths, S<:GeneralState{Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths}}
    merged = Symbol[ExplicitlySharedFields...]
    for field in fields
        field in Fields || continue
        field in merged || push!(merged, field)
    end
    return GeneralState(state.default_values_builder, Val{Fields}(), Val{Required}(), Val{tuple(merged...)}(), Val{DiagnosticFieldPaths}())
end

"""Return a copy of `state` whose diagnostic field paths are prefixed by `prefix`.

When a child routine is added as `@context f = child()`, a nested field named
`buffers` should warn as `f.buffers` rather than plain `buffers`. This function
only changes that warning path.
"""
function prefix_general_state_diagnostic_paths(state::S, prefix::Symbol) where {Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths, S<:GeneralState{Fields, Required, DefaultValuesBuilder, ExplicitlySharedFields, DiagnosticFieldPaths}}
    diagnostic_paths = ntuple(i -> (prefix, DiagnosticFieldPaths[i]...), length(Fields))
    return GeneralState(state.default_values_builder, Val{Fields}(), Val{Required}(), Val{ExplicitlySharedFields}(), Val{diagnostic_paths}())
end

"""Format one field path for state-overlap diagnostics."""
function _general_state_diagnostic_path(fields::F, diagnostic_paths::P, name::Symbol) where {F<:Tuple, P<:Tuple}
    idx = findfirst(==(name), fields)
    path = isnothing(idx) ? (name,) : diagnostic_paths[idx]
    return join(string.(path), ".")
end

"""Suggest the explicit DSL state composition statement for one overlap."""
function _general_state_overlap_suggestion(left::L, right::R) where {L<:AbstractString, R<:AbstractString}
    left_is_child = occursin(".", left)
    right_is_child = occursin(".", right)
    if left_is_child && right_is_child
        return string("@merge ", left, ", ", right)
    elseif left_is_child
        return string("@bind ", right, " => ", left)
    elseif right_is_child
        return string("@bind ", left, " => ", right)
    end
    return string("@merge ", left, ", ", right)
end

"""Warn for state overlaps that have not been explicitly documented."""
function _warn_general_state_overlaps(fields_a::FA, fields_b::FB, required_a::RA, required_b::RB, explicitly_shared_a::SA, explicitly_shared_b::SB, diagnostic_paths_a::PA, diagnostic_paths_b::PB) where {FA<:Tuple, FB<:Tuple, RA<:Tuple, RB<:Tuple, SA<:Tuple, SB<:Tuple, PA<:Tuple, PB<:Tuple}
    overlaps = filter(name -> name in fields_a, fields_b)
    isempty(overlaps) && return nothing

    undocumented = filter(name -> !(name in explicitly_shared_a) && !(name in explicitly_shared_b), overlaps)
    default_conflicts = filter(name -> !(name in required_a) && !(name in required_b), overlaps)
    isempty(undocumented) && isempty(default_conflicts) && return nothing

    diagnostic_paths = map(overlaps) do name
        (_general_state_diagnostic_path(fields_a, diagnostic_paths_a, name), _general_state_diagnostic_path(fields_b, diagnostic_paths_b, name))
    end
    paths = map(pair -> string(pair[1], " <=> ", pair[2]), diagnostic_paths)
    suggestions = map(pair -> _general_state_overlap_suggestion(pair[1], pair[2]), diagnostic_paths)
    if isempty(undocumented)
        @warn "Overlapping GeneralState field names have multiple defaults at $(join(paths, ", ")); later defaults will override earlier ones." overlapping_fields = collect(overlaps) state_paths = paths default_conflicts = collect(default_conflicts)
    else
        @warn "Overlapping GeneralState field names encountered during merge at $(join(paths, ", ")); add an explicit DSL state statement such as $(join(suggestions, " or ")) when this sharing is intentional." overlapping_fields = collect(undocumented) state_paths = paths suggested_fixes = suggestions default_conflicts = collect(default_conflicts)
    end
    return nothing
end

function _merge_general_state_fields(fields_a::FA, fields_b::FB) where {FA<:Tuple, FB<:Tuple}
    overlaps = filter(name -> name in fields_a, fields_b)
    merged = Symbol[fields_a...]
    for name in fields_b
        name in merged || push!(merged, name)
    end
    return tuple(merged...)
end

"""Return the ordered union of two symbol tuples."""
function _general_state_symbol_union(left::L, right::R) where {L<:Tuple, R<:Tuple}
    merged = Symbol[left...]
    for name in right
        name in merged || push!(merged, name)
    end
    return tuple(merged...)
end

"""Merge required-state flags, letting any defaulted declaration satisfy a field."""
function _merge_general_state_required_fields(fields::F, fields_a::FA, required_a::RA, fields_b::FB, required_b::RB) where {F<:Tuple, FA<:Tuple, RA<:Tuple, FB<:Tuple, RB<:Tuple}
    required = Symbol[]
    for field in fields
        required_in_a = field in fields_a && field in required_a
        required_in_b = field in fields_b && field in required_b
        defaulted_in_a = field in fields_a && !(field in required_a)
        defaulted_in_b = field in fields_b && !(field in required_b)
        if (required_in_a || required_in_b) && !defaulted_in_a && !defaulted_in_b
            push!(required, field)
        end
    end
    return tuple(required...)
end

"""
Merge two `GeneralState` initialization schemes.

This is intended for higher-level registry/setup code that decides two state
entries with the same outer key should coalesce. If both states define the same
field name, the merge continues with a warning and the later state's defaults
override the earlier state's defaults for that field.
"""
function Base.merge(
    a::GeneralState{FieldsA, RequiredA, DefaultValuesBuilderA, ExplicitlySharedFieldsA, DiagnosticFieldPathsA},
    b::GeneralState{FieldsB, RequiredB, DefaultValuesBuilderB, ExplicitlySharedFieldsB, DiagnosticFieldPathsB},
) where {FieldsA, RequiredA, DefaultValuesBuilderA, ExplicitlySharedFieldsA, DiagnosticFieldPathsA, FieldsB, RequiredB, DefaultValuesBuilderB, ExplicitlySharedFieldsB, DiagnosticFieldPathsB}
    _warn_general_state_overlaps(FieldsA, FieldsB, RequiredA, RequiredB, ExplicitlySharedFieldsA, ExplicitlySharedFieldsB, DiagnosticFieldPathsA, DiagnosticFieldPathsB)
    merged_fields = _merge_general_state_fields(FieldsA, FieldsB)
    merged_required = _merge_general_state_required_fields(merged_fields, FieldsA, RequiredA, FieldsB, RequiredB)
    merged_explicitly_shared_fields = _general_state_symbol_union(ExplicitlySharedFieldsA, ExplicitlySharedFieldsB)
    merged_diagnostic_paths = ntuple(length(merged_fields)) do i
        field = merged_fields[i]
        idx_b = findfirst(==(field), FieldsB)
        if !isnothing(idx_b)
            return DiagnosticFieldPathsB[idx_b]
        end
        idx_a = findfirst(==(field), FieldsA)
        return DiagnosticFieldPathsA[idx_a]
    end
    merged_builder = let a = a, b = b
        () -> merge(a.default_values_builder(), b.default_values_builder())
    end
    return GeneralState(merged_builder, Val{merged_fields}(), Val{merged_required}(), Val{merged_explicitly_shared_fields}(), Val{merged_diagnostic_paths}())
end

"""Fetch a required state input or raise a readable error."""
@inline function _general_state_required(context, name::Symbol, state)
    haskey(context, name) || error("LoopAlgorithm @state requires input `$(name)` during init for $(summary(state)).")
    return getproperty(context, name)
end

"""Fetch an optional state input, falling back to the generated default if the source is not initialized yet."""
@inline function _general_state_optional(context, name::Symbol, default)
    haskey(context, name) || return default
    try
        return getproperty(context, name)
    catch
        return default
    end
end

"""Initialize a `GeneralState` from a context or plain named tuple."""
@generated function StatefulAlgorithms.init(state::GeneralState{Fields, Required, DefaultValuesBuilder}, context::C) where {Fields, Required, DefaultValuesBuilder, C <: Union{StatefulAlgorithms.AbstractContext, NamedTuple}}
    values = Expr[]
    for field in Fields
        if field in Required
            push!(values, :(_general_state_required(context, $(QuoteNode(field)), state)))
        else
            push!(values, :(_general_state_optional(context, $(QuoteNode(field)), getproperty(defaults, $(QuoteNode(field))))))
        end
    end

    nt_type = Expr(:curly, :NamedTuple, QuoteNode(Fields))
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        local defaults = state.default_values_builder()
        return $nt_type(($(values...),))
    end
end
