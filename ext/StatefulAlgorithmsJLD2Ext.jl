module StatefulAlgorithmsJLD2Ext

using StatefulAlgorithms, JLD2
import StatefulAlgorithms: savecontext, loadcontext, contextdata

savecontext(p::Process, filename::AbstractString) = savecontext(getcontext(p), filename)
savecontext(context::StatefulAlgorithms.ProcessContext, filename::AbstractString) =
    jldsave(filename; context = contextdata(context))

loadcontext(filename::AbstractString) = JLD2.load(filename, "context")

end
