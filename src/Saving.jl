export savecontext, loadcontext

"""
    savecontext(p::Process, filename)
    savecontext(context::ProcessContext, filename)

Save the persistent data of a process context to a JLD2 file: a `NamedTuple`
with one entry per subcontext key, each holding that subcontext's variables.

Requires `using JLD2`; the method lives in the `StatefulAlgorithmsJLD2Ext` extension.
"""
function savecontext end

"""
    loadcontext(filename)

Load the data written by [`savecontext`](@ref): a `NamedTuple` keyed by
subcontext key, e.g. `loadcontext(file).Counter_1.count`.

Requires `using JLD2`.
"""
function loadcontext end

"""Persistent data of a context as a `NamedTuple` of `NamedTuple`s, keyed by subcontext key."""
contextdata(context::ProcessContext) = map(getdata, get_subcontexts(context))
