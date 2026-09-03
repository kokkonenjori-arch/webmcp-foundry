# budget.jl — invocation budgets: "over-broad in time" is refused like over-broad inputs.
#
# A contract may declare
#   budget = { "max_per_hour": N,             # successful invocations per human session per trailing hour
#              "max_amount_per_hour": A,      # sum of `amount_field` over the same window
#              "amount_field": "amount_cents" }
# The GATEWAY enforces it from the ledger (INVOKED events with 2xx status), so the limit is a
# property of the recorded history, not of any in-memory counter, and replay reproduces it.

module Budget

using Dates

export budget_usage, budget_check, parse_at

parse_at(s::AbstractString) = try DateTime(String(s)[1:19], dateformat"yyyy-mm-ddTHH:MM:SS") catch; DateTime(1970) end

"Usage within the trailing hour for one capability and one human session: (count, amount)."
function budget_usage(events, capability_id::String, session_user::String, now::DateTime; amount_field::String="")
    count = 0; amount = 0
    for e in events
        e.kind == "INVOKED" || continue
        p = e.payload
        get(p, "capability_id", "") == capability_id || continue
        get(p, "session_user", "") == session_user || continue
        st = get(p, "status", 0)
        (st isa Number && 200 <= st < 300) || continue
        now - parse_at(e.at) <= Hour(1) || continue
        count += 1
        if !isempty(amount_field)
            v = tryparse(Int, string(get(get(p, "bound", Dict()), amount_field, "0")))
            v === nothing || (amount += abs(v))
        end
    end
    (count, amount)
end

"""
    budget_check(budget, events, capability_id, session_user, bound, now) -> (ok, reasons, usage)

Would one more invocation with `bound` input exceed the budget? Empty budget ⇒ ok.
"""
function budget_check(budget::Dict{String,Any}, events, capability_id::String, session_user::String,
                      bound::Dict{String,String}, now::DateTime)
    isempty(budget) && return (true, String[], Dict{String,Any}())
    af = string(get(budget, "amount_field", ""))
    count, amount = budget_usage(events, capability_id, session_user, now; amount_field=af)
    reasons = String[]
    maxn = get(budget, "max_per_hour", nothing)
    maxa = get(budget, "max_amount_per_hour", nothing)
    maxn !== nothing && count + 1 > maxn && push!(reasons, "invocation budget: $count of $maxn per hour already used by session $session_user")
    this = isempty(af) ? 0 : abs(something(tryparse(Int, get(bound, af, "0")), 0))
    maxa !== nothing && !isempty(af) && amount + this > maxa &&
        push!(reasons, "amount budget: $amount + $this would exceed $maxa $af per hour for session $session_user")
    usage = Dict{String,Any}("count" => count, "amount" => amount, "max_per_hour" => maxn, "max_amount_per_hour" => maxa, "amount_field" => af)
    (isempty(reasons), reasons, usage)
end

end # module Budget
