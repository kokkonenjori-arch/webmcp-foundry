# transfer_funds — FINANCIAL. VERSION 2: memo is normalised (collapsed
# whitespace) and the audit line records the memo. A benign change — but any
# change to this artifact invalidates evidence gathered against version 1.
function handle_transfer_funds(st::AppState, user::String, input::Dict{String,String})
    from = get(input, "from_account", "")
    to = get(input, "to_account", "")
    amount = tryparse(Int, get(input, "amount_cents", ""))
    amount === nothing && return (422, Dict("error" => "amount_cents must be an integer"))
    amount > 0 || return (422, Dict("error" => "amount must be positive"))
    amount <= 25000 || return (422, Dict("error" => "amount exceeds per-transfer limit"))
    memo = replace(strip(get(input, "memo", "")), r"\s+" => " ")
    length(memo) > 120 && return (422, Dict("error" => "memo too long"))
    haskey(st.accounts, from) || return (404, Dict("error" => "unknown source account"))
    haskey(st.accounts, to) || return (404, Dict("error" => "unknown destination account"))
    from == to && return (422, Dict("error" => "source and destination must differ"))
    st.accounts[from]["owner"] == user || return (403, Dict("error" => "not your account"))
    st.accounts[from]["balance_cents"] >= amount || return (422, Dict("error" => "insufficient funds"))
    st.accounts[from]["balance_cents"] -= amount
    st.accounts[to]["balance_cents"] += amount
    t1 = Dict{String,Any}("id" => newid!(st, "T"), "account" => from, "amount_cents" => -amount, "memo" => "transfer to $to: $memo", "kind" => "debit")
    t2 = Dict{String,Any}("id" => newid!(st, "T"), "account" => to, "amount_cents" => amount, "memo" => "transfer from $from: $memo", "kind" => "credit")
    push!(st.transactions, t1); push!(st.transactions, t2)
    push!(st.audit, "$user transferred $amount from $from to $to ($memo)")
    (201, Dict("debit" => t1, "credit" => t2, "from_balance_cents" => st.accounts[from]["balance_cents"]))
end
