# _money.jl — SHARED money helper used by apply_adjustment and transfer_funds.
# A change here is a change to every capability that depends on it (blast radius).
function apply_delta!(st::AppState, account::String, amount::Int, memo::String)
    st.accounts[account]["balance_cents"] += amount
    t = Dict{String,Any}("id" => newid!(st, "T"), "account" => account, "amount_cents" => amount,
                         "memo" => memo, "kind" => amount > 0 ? "credit" : "debit")
    push!(st.transactions, t)
    t
end
