# _money.jl — SHARED money helper used by apply_adjustment and transfer_funds.
# VERSION 2: rounds memos and tags every posting with the helper version. Benign — but it is a
# change to an artifact two capabilities depend on, so both must be re-qualified.
function apply_delta!(st::AppState, account::String, amount::Int, memo::String)
    st.accounts[account]["balance_cents"] += amount
    t = Dict{String,Any}("id" => newid!(st, "T"), "account" => account, "amount_cents" => amount,
                         "memo" => strip(memo), "kind" => amount > 0 ? "credit" : "debit", "posted_by" => "money/v2")
    push!(st.transactions, t)
    t
end
