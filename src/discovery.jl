# discovery.jl — model candidate capabilities from a human-facing page.
#
# Non-goal: understanding arbitrary JavaScript. Discovery reads the DECLARED
# human surface — HTML <form> elements and their controls — which is exactly
# what a human can do on the page. Everything discovered is over-broad by
# construction: every control (including hidden ones) is initially agent-bound
# and unconstrained beyond what the markup states. Page hints (data-effect,
# data-scope) are recorded as UNTRUSTED claims.

module Discovery

import ..JSON: canonical
import ..Model: Candidate, FieldSpec, ActionRef, AGENT_BOUND, sha

export discover_forms, scan_html

# ------------------------------------------------------------------ tiny HTML scanner

"Return a vector of (tagname, attrs::Dict, is_closing) for every tag in `html`, in order."
function scan_html(html::AbstractString)
    tags = Tuple{String,Dict{String,String},Bool}[]
    i = firstindex(html)
    n = lastindex(html)
    while i <= n
        j = findnext('<', html, i)
        j === nothing && break
        k = findnext('>', html, j)
        k === nothing && break
        inner = html[nextind(html, j):prevind(html, k)]
        i = nextind(html, k)
        (startswith(inner, "!") || startswith(inner, "?")) && continue
        closing = startswith(inner, "/")
        closing && (inner = inner[2:end])
        endswith(inner, "/") && (inner = inner[1:end-1])
        parts = split(strip(inner); limit=2)
        isempty(parts) && continue
        name = lowercase(String(parts[1]))
        attrs = Dict{String,String}()
        if length(parts) == 2
            for m in eachmatch(r"([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+)))?", parts[2])
                key = lowercase(m.captures[1])
                val = m.captures[2] !== nothing ? m.captures[2] :
                      m.captures[3] !== nothing ? m.captures[3] :
                      m.captures[4] !== nothing ? m.captures[4] : ""
                attrs[key] = String(val)
            end
        end
        push!(tags, (name, attrs, closing))
    end
    tags
end

# ------------------------------------------------------------------ forms -> candidates

function field_from_control(tag::String, a::Dict{String,String}, options::Vector{String})
    name = get(a, "name", "")
    itype = lowercase(get(a, "type", tag == "select" ? "select" : (tag == "textarea" ? "textarea" : "text")))
    cons = Dict{String,Any}()
    origin = "visible"
    ftype = "string"
    if itype == "hidden"
        origin = "hidden"
        cons["default"] = get(a, "value", "")
    elseif itype == "number"
        ftype = "integer"
        haskey(a, "min") && (cons["minimum"] = parse(Int, a["min"]))
        haskey(a, "max") && (cons["maximum"] = parse(Int, a["max"]))
    elseif itype == "checkbox"
        ftype = "boolean"
    elseif tag == "select"
        ftype = "enum"; origin = "select"
        cons["enum"] = options
    elseif itype == "email"
        cons["format"] = "email"
    end
    haskey(a, "maxlength") && (cons["maxLength"] = parse(Int, a["maxlength"]))
    haskey(a, "pattern") && (cons["pattern"] = a["pattern"])
    get(a, "data-human-only", "") == "true" && (origin = "human-only")
    required = haskey(a, "required") || itype == "hidden"
    FieldSpec(name, ftype, AGENT_BOUND, required, cons, origin)
end

"""
    discover_forms(html, app_id, source_map) -> Vector{Candidate}

`source_map` maps action name -> source_ref (so the candidate can be tied to the
artifact that implements it). Forms without data-action are ignored.
"""
function discover_forms(html::AbstractString, app_id::String, source_map::AbstractDict)
    tags = scan_html(html)
    cands = Candidate[]
    i = 1
    while i <= length(tags)
        name, attrs, closing = tags[i]
        if name == "form" && !closing && haskey(attrs, "data-action")
            action = attrs["data-action"]
            fields = FieldSpec[]
            hints = Dict{String,Any}()
            for (k, v) in attrs
                startswith(k, "data-") && k != "data-action" && (hints[k[6:end]] = v)
            end
            j = i + 1
            while j <= length(tags) && !(tags[j][1] == "form" && tags[j][3])
                t, a, c = tags[j]
                if !c && t in ("input", "textarea") && haskey(a, "name")
                    push!(fields, field_from_control(t, a, String[]))
                elseif !c && t == "select" && haskey(a, "name")
                    opts = String[]
                    k = j + 1
                    while k <= length(tags) && !(tags[k][1] == "select" && tags[k][3])
                        tags[k][1] == "option" && !tags[k][3] && push!(opts, get(tags[k][2], "value", ""))
                        k += 1
                    end
                    push!(fields, field_from_control(t, a, opts))
                    j = k
                end
                j += 1
            end
            ref = ActionRef(app_id, uppercase(get(attrs, "method", "get")), get(attrs, "action", "/"),
                            String(get(source_map, action, "unknown")))
            surface = Dict{String,Any}("action" => action, "method" => ref.method, "path" => ref.path,
                "fields" => [Dict("name" => f.name, "type" => f.type, "origin" => f.origin, "constraints" => f.constraints, "required" => f.required) for f in fields],
                "hints" => hints)
            push!(cands, Candidate("$app_id.$action", replace(action, "_" => " "), ref, fields, hints, sha(canonical(surface))))
            i = j
        end
        i += 1
    end
    cands
end

end # module Discovery
