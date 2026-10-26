# function total_incs(sr::SubRoutine)
#     if is_decomposable(sr)
#         return repeats(sr) * total_incs(sr.func)
#     else
#         return repeats(sr)
#     end
# end

# function total_incs(sc::SubComposite{F,I}) where {F,I}
#     if is_decomposable(sc)
#         return total_incs(sc.func)/I
#     else
#         return 1/I
#     end
# end

function total_incs(plan::Plan)
    return 1 + sum(total_incs(getalgo(plan, i)) * schedule_multiplier(getschedule(plan)[i]) for i in 1:length(plan))
end
