
########################
### SHOWING ###
########################


@inline _target_label(x) = string(x)
@inline _target_label(x::Symbol) = String(x)
@inline _target_label(::Type{T}) where {T} = string(nameof(T))
@inline _target_label(::Type{AllInitTargets}) = "all"
@inline _target_label(::Nothing) = "nothing"

function Base.summary(io::IO, ov::Input)
    print(io, "Input(target=", _target_label(get_target(ov)), ", ref=", _target_label(get_ref(ov)), ", vars=", get_vars(ov), ")")
end

function Base.show(io::IO, ov::Input)
    summary(io, ov)
end

function Base.summary(io::IO, ov::Override)
    print(io, "Override(target=", _target_label(get_target(ov)), ", ref=", _target_label(get_ref(ov)), ", vars=", get_vars(ov), ")")
end

function Base.show(io::IO, ov::Override)
    summary(io, ov)
end

function Base.summary(io::IO, spec::Interactive)
    print(io, "Interactive(target=", _target_label(get_target(spec)), ", ref=", _target_label(get_ref(spec)), ", vars=", interactive_names(spec), ")")
end

function Base.show(io::IO, spec::Interactive)
    summary(io, spec)
end
