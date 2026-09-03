# delete_account — DESTRUCTIVE. Irreversibly removes an account the caller owns.
function handle_delete_account(st::AppState, user::String, input::Dict{String,String})
    account = get(input, "account_id", "")
    get(input, "confirm", "") == "DELETE" || return (422, Dict("error" => "type DELETE to confirm"))
    haskey(st.accounts, account) || return (404, Dict("error" => "unknown account"))
    st.accounts[account]["owner"] == user || return (403, Dict("error" => "not your account"))
    delete!(st.accounts, account)
    filter!(t -> t["account"] != account, st.transactions)
    push!(st.audit, "$user deleted $account")
    (200, Dict("deleted" => account))
end
