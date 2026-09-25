export savecontext

"""
    savecontext(process, filename = "")

Save the current process context through the legacy JLD2 keyword-splat format.

This entry point is retained for compatibility. Its persistence format needs a
versioned replacement before it should be used for new long-lived data.
"""
function savecontext(p::Process, filename = "")
    # TODO: Replace this legacy keyword-splat format with versioned context
    # serialization and an explicit load/migration path.
    jldsave("contextsave_$filename.jld2"; getcontext(p)...)
end
