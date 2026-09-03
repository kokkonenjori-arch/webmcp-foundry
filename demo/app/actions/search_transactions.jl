# search_transactions — READ. Lists transactions for one account (or every
# account if the caller sets include_all_accounts=1: an over-broad knob that a
# human UI hides but a naive agent surface would expose).
function handle_search_transactions(st::AppState, user::String, input::Dict{String,String})
    q = lowercase(get(input, "q", ""))
    limit = something(tryparse(Int, get(input, "limit", "20")), 20)
    (1 <= limit <= 100) || return (422, Dict("error" => "limit must be 1..100"))
    account = get(input, "account_id", "")
    all = get(input, "include_all_accounts", "0") == "1"
    if !all
        haskey(st.accounts, account) || return (404, Dict("error" => "unknown account"))
        st.accounts[account]["owner"] == user || return (403, Dict("error" => "not your account"))
    end
    rows = [t for t in st.transactions if (all || t["account"] == account) && occursin(q, lowercase(t["memo"]))]
    (200, Dict("results" => rows[1:min(limit, length(rows))], "count" => length(rows)))
end
