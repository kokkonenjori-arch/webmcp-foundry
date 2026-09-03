# apply_adjustment — declared as a WRITE_OWN correction to one of the caller's
# accounts. VERSION 1 IS INTENTIONALLY INCORRECT: it never checks that the caller
# owns the account, so any account listed in the form can be debited.
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
    # BUG (v1): missing ownership check — see apply_adjustment.v2.jl for the repair
    t = apply_delta!(st, account, amount, "adjustment: " * String(reason))
    push!(st.audit, "$user adjusted $account by $amount")
    (201, Dict("transaction" => t, "balance_cents" => st.accounts[account]["balance_cents"]))
end
