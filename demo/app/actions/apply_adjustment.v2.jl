# apply_adjustment — WRITE_OWN correction to one of the caller's accounts.
# VERSION 2 (repaired): ownership is checked before any mutation.
function handle_apply_adjustment(st::AppState, user::String, input::Dict{String,String})
    account = get(input, "account_id", "")
    amount = tryparse(Int, get(input, "amount_cents", ""))
    amount === nothing && return (422, Dict("error" => "amount_cents must be an integer"))
    amount == 0 && return (422, Dict("error" => "amount must be non-zero"))
    abs(amount) > 100000 && return (422, Dict("error" => "amount exceeds adjustment limit"))
    reason = strip(get(input, "reason", ""))
    isempty(reason) && return (422, Dict("error" => "reason required"))
    haskey(st.accounts, account) || return (404, Dict("error" => "unknown account"))
    st.accounts[account]["balance_cents"] + amount >= 0 || return (422, Dict("error" => "adjustment would overdraw the account"))
    st.accounts[account]["owner"] == user || return (403, Dict("error" => "not your account"))
    st.accounts[account]["balance_cents"] += amount
    t = Dict{String,Any}("id" => newid!(st, "T"), "account" => account, "amount_cents" => amount,
                         "memo" => "adjustment: " * String(reason), "kind" => amount > 0 ? "credit" : "debit")
    push!(st.transactions, t)
    push!(st.audit, "$user adjusted $account by $amount")
    (201, Dict("transaction" => t, "balance_cents" => st.accounts[account]["balance_cents"]))
end
