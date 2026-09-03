# share_report — EXTERNAL_SEND. Hands a report to the outbound mail relay. The
# app can only observe the hand-off, not delivery: the side effect leaves the
# system boundary.
function handle_share_report(st::AppState, user::String, input::Dict{String,String})
    to = strip(get(input, "recipient_email", ""))
    occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", to) || return (422, Dict("error" => "invalid email"))
    period = get(input, "period", "month")
    period in ("month", "quarter") || return (422, Dict("error" => "period must be month or quarter"))
    owned = sort!([k for (k, a) in st.accounts if a["owner"] == user])
    msg = Dict{String,Any}("to" => String(to), "period" => period, "accounts" => owned, "by" => user)
    push!(st.outbox, msg)     # relay picks this up asynchronously; delivery is unobservable here
    push!(st.audit, "$user shared $period report with $to")
    (202, Dict("queued" => true, "recipient" => String(to)))
end
