# validate.jl — the gateway's input validator: agent input -> bound app input.
#
# This is the one place agent-controlled data becomes an app request. Rules:
#   * unknown keys are refused (no pass-through surface);
#   * SESSION/FIXED/HUMAN_ONLY fields supplied by the agent are refused, never
#     silently overwritten — an attempt to control a bound field is a finding;
#   * AGENT fields are type-checked and constraint-checked;
#   * SESSION fields are bound from the resolved session (user_id, default_account);
#   * a required HUMAN_ONLY field makes the input un-bindable (refused).
# Returns (ok, bound::Dict{String,String}, errors::Vector{String}).

module Validate

import ..Model: Contract, FieldSpec, AGENT_BOUND, SESSION_BOUND, FIXED_BOUND, HUMAN_ONLY

export bind_input, input_schema

const INJECTION_MARKERS = ["<script", "javascript:", "\0", "\$" * "{", "../"]

function check_agent_value(f::FieldSpec, v)
    errs = String[]
    c = f.constraints
    if f.type == "integer"
        iv = v isa Integer ? Int(v) : (v isa AbstractString ? tryparse(Int, v) : (v isa AbstractFloat && isinteger(v) ? Int(v) : nothing))
        iv === nothing && return (nothing, ["$(f.name): expected integer, got $(repr(v))"])
        haskey(c, "minimum") && iv < c["minimum"] && push!(errs, "$(f.name): $iv < minimum $(c["minimum"])")
        haskey(c, "maximum") && iv > c["maximum"] && push!(errs, "$(f.name): $iv > maximum $(c["maximum"])")
        return (string(iv), errs)
    elseif f.type == "boolean"
        bv = v isa Bool ? v : (v in ("1", "true", true) ? true : (v in ("0", "false", false, "") ? false : nothing))
        bv === nothing && return (nothing, ["$(f.name): expected boolean"])
        return (bv ? "1" : "0", errs)
    elseif f.type == "enum"
        sv = string(v)
        sv in c["enum"] || push!(errs, "$(f.name): $(repr(sv)) not in enum $(c["enum"])")
        return (sv, errs)
    else
        v isa AbstractString || return (nothing, ["$(f.name): expected string"])
        sv = String(v)
        haskey(c, "maxLength") && length(sv) > c["maxLength"] && push!(errs, "$(f.name): length $(length(sv)) > maxLength $(c["maxLength"])")
        haskey(c, "pattern") && !occursin(Regex(c["pattern"]), sv) && push!(errs, "$(f.name): does not match pattern")
        get(c, "format", "") == "email" && !occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", sv) && push!(errs, "$(f.name): not an email")
        for m in INJECTION_MARKERS
            occursin(m, sv) && push!(errs, "$(f.name): contains refused marker $(repr(m))")
        end
        return (sv, errs)
    end
end

function bind_input(k::Contract, agent_input::Dict{String,Any}, session::Dict{String,Any})
    errs = String[]
    bound = Dict{String,String}()
    names = Set(f.name for f in k.inputs)
    for key in keys(agent_input)
        key in names || push!(errs, "unknown field $(repr(key)) refused")
    end
    for f in k.inputs
        supplied = haskey(agent_input, f.name)
        if f.binding == AGENT_BOUND
            if !supplied
                f.required && push!(errs, "$(f.name): required")
                continue
            end
            v, e = check_agent_value(f, agent_input[f.name])
            append!(errs, e)
            v === nothing || (bound[f.name] = v)
        elseif f.binding == SESSION_BOUND
            supplied && push!(errs, "$(f.name): session-bound field is not agent-controlled")
            sk = get(f.constraints, "session_key", "user_id")
            haskey(session, sk) || (push!(errs, "$(f.name): session has no $(sk)"); continue)
            bound[f.name] = string(session[sk])
        elseif f.binding == FIXED_BOUND
            supplied && push!(errs, "$(f.name): fixed field is not agent-controlled")
            bound[f.name] = string(get(f.constraints, "fixed", ""))
        elseif f.binding == HUMAN_ONLY
            supplied && push!(errs, "$(f.name): human-only field cannot be supplied by an agent")
            f.required && push!(errs, "$(f.name): required human-only input cannot be bound for an agent")
        end
    end
    (isempty(errs), bound, errs)
end

"JSON-Schema-style input schema for WebMCP: ONLY agent-bound fields appear."
function input_schema(k::Contract)
    props = Dict{String,Any}()
    req = String[]
    for f in k.inputs
        f.binding == AGENT_BOUND || continue
        p = Dict{String,Any}()
        if f.type == "integer"
            p["type"] = "integer"
            haskey(f.constraints, "minimum") && (p["minimum"] = f.constraints["minimum"])
            haskey(f.constraints, "maximum") && (p["maximum"] = f.constraints["maximum"])
        elseif f.type == "boolean"
            p["type"] = "boolean"
        elseif f.type == "enum"
            p["type"] = "string"; p["enum"] = f.constraints["enum"]
        else
            p["type"] = "string"
            haskey(f.constraints, "maxLength") && (p["maxLength"] = f.constraints["maxLength"])
            haskey(f.constraints, "pattern") && (p["pattern"] = f.constraints["pattern"])
            get(f.constraints, "format", "") == "email" && (p["format"] = "email")
        end
        props[f.name] = p
        f.required && push!(req, f.name)
    end
    Dict{String,Any}("type" => "object", "properties" => props, "required" => sort!(req), "additionalProperties" => false)
end

end # module Validate
