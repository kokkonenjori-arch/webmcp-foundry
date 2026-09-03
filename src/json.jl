# json.jl — minimal, dependency-free JSON codec with CANONICAL encoding.
#
# Canonical form (used for hashing evidence, contracts, ledger entries):
#   * object keys sorted bytewise
#   * no insignificant whitespace
#   * integral floats printed as integers; other floats via shortest round-trip repr
#   * strings escaped per RFC 8259 (mandatory escapes + control chars)
#
# Decoding produces: Dict{String,Any}, Vector{Any}, String, Int64/Float64, Bool, nothing.
# Doctrine (Loft): a codec used for evidence must be byte-stable across runs.

module JSON

export json, canonical, parse_json, JSONError

struct JSONError <: Exception
    msg::String
    pos::Int
end
Base.showerror(io::IO, e::JSONError) = print(io, "JSONError at ", e.pos, ": ", e.msg)

# ---------------------------------------------------------------- encoding

function _escape(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'; print(io, "\\\"")
        elseif c == '\\'; print(io, "\\\\")
        elseif c == '\n'; print(io, "\\n")
        elseif c == '\r'; print(io, "\\r")
        elseif c == '\t'; print(io, "\\t")
        elseif c == '\b'; print(io, "\\b")
        elseif c == '\f'; print(io, "\\f")
        elseif UInt32(c) < 0x20
            print(io, "\\u", lpad(string(UInt32(c), base=16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
end

_write(io::IO, ::Nothing, ::Bool) = print(io, "null")
_write(io::IO, ::Missing, ::Bool) = print(io, "null")
_write(io::IO, b::Bool, ::Bool) = print(io, b ? "true" : "false")
_write(io::IO, n::Integer, ::Bool) = print(io, n)
function _write(io::IO, x::AbstractFloat, ::Bool)
    if isfinite(x)
        if x == floor(x) && abs(x) < 1e15
            print(io, Int64(x))          # canonical: 3.0 -> 3
        else
            print(io, repr(x))
        end
    else
        print(io, "null")                 # NaN/Inf are not JSON; fail closed to null
    end
end
_write(io::IO, s::AbstractString, ::Bool) = _escape(io, s)
_write(io::IO, s::Symbol, ::Bool) = _escape(io, String(s))
_write(io::IO, e::Enum, ::Bool) = _escape(io, string(e))

function _write(io::IO, v::Union{AbstractVector,Tuple,AbstractSet}, canon::Bool)
    print(io, '[')
    firstitem = true
    items = v isa AbstractSet ? sort!(collect(v); by=string) : v
    for x in items
        firstitem || print(io, ',')
        firstitem = false
        _write(io, x, canon)
    end
    print(io, ']')
end

function _write(io::IO, d::AbstractDict, canon::Bool)
    print(io, '{')
    pairs_ = [(string(k), v) for (k, v) in d]
    canon && sort!(pairs_; by=p->p[1])
    firstitem = true
    for (k, v) in pairs_
        firstitem || print(io, ',')
        firstitem = false
        _escape(io, k)
        print(io, ':')
        _write(io, v, canon)
    end
    print(io, '}')
end

# Structs: encode public fields as an object.
function _write(io::IO, x::T, canon::Bool) where {T}
    if isstructtype(T)
        d = Dict{String,Any}()
        for f in fieldnames(T)
            d[string(f)] = getfield(x, f)
        end
        _write(io, d, canon)
    else
        _escape(io, string(x))
    end
end

"json(x) -> String  (insertion-ordered objects; for transport, not hashing)"
function json(x)
    io = IOBuffer(); _write(io, x, false); String(take!(io))
end
"canonical(x) -> String  (sorted keys; the ONLY form used for hashing)"
function canonical(x)
    io = IOBuffer(); _write(io, x, true); String(take!(io))
end

# ---------------------------------------------------------------- decoding

mutable struct Parser
    s::Vector{UInt8}
    i::Int
end

peek(p::Parser) = p.i <= length(p.s) ? p.s[p.i] : 0x00
function skipws(p::Parser)
    while p.i <= length(p.s) && (p.s[p.i] in (0x20, 0x09, 0x0a, 0x0d))
        p.i += 1
    end
end
function expect(p::Parser, c::UInt8)
    peek(p) == c || throw(JSONError("expected '$(Char(c))'", p.i))
    p.i += 1
end

function parse_json(str::AbstractString)
    p = Parser(Vector{UInt8}(codeunits(str)), 1)
    skipws(p)
    v = parse_value(p)
    skipws(p)
    p.i > length(p.s) || throw(JSONError("trailing characters", p.i))
    v
end

function parse_value(p::Parser)
    skipws(p)
    c = peek(p)
    c == UInt8('{') && return parse_object(p)
    c == UInt8('[') && return parse_array(p)
    c == UInt8('"') && return parse_string(p)
    c == UInt8('t') && return (parse_lit(p, "true"); true)
    c == UInt8('f') && return (parse_lit(p, "false"); false)
    c == UInt8('n') && return (parse_lit(p, "null"); nothing)
    (c == UInt8('-') || (UInt8('0') <= c <= UInt8('9'))) && return parse_number(p)
    throw(JSONError("unexpected character '$(Char(c))'", p.i))
end

function parse_lit(p::Parser, lit::String)
    for ch in codeunits(lit)
        peek(p) == ch || throw(JSONError("bad literal", p.i))
        p.i += 1
    end
end

function parse_number(p::Parser)
    start = p.i
    isfloat = false
    peek(p) == UInt8('-') && (p.i += 1)
    while p.i <= length(p.s)
        c = p.s[p.i]
        if UInt8('0') <= c <= UInt8('9')
            p.i += 1
        elseif c in (UInt8('.'), UInt8('e'), UInt8('E'), UInt8('+'), UInt8('-'))
            isfloat = true; p.i += 1
        else
            break
        end
    end
    txt = String(p.s[start:p.i-1])
    if isfloat
        v = tryparse(Float64, txt)
        v === nothing && throw(JSONError("bad number '$txt'", start))
        return v
    else
        v = tryparse(Int64, txt)
        v === nothing && (v = tryparse(Float64, txt))
        v === nothing && throw(JSONError("bad number '$txt'", start))
        return v
    end
end

function parse_string(p::Parser)
    expect(p, UInt8('"'))
    io = IOBuffer()
    while true
        p.i <= length(p.s) || throw(JSONError("unterminated string", p.i))
        c = p.s[p.i]
        if c == UInt8('"')
            p.i += 1
            return String(take!(io))
        elseif c == UInt8('\\')
            p.i += 1
            e = peek(p); p.i += 1
            if e == UInt8('"'); write(io, '"')
            elseif e == UInt8('\\'); write(io, '\\')
            elseif e == UInt8('/'); write(io, '/')
            elseif e == UInt8('b'); write(io, '\b')
            elseif e == UInt8('f'); write(io, '\f')
            elseif e == UInt8('n'); write(io, '\n')
            elseif e == UInt8('r'); write(io, '\r')
            elseif e == UInt8('t'); write(io, '\t')
            elseif e == UInt8('u')
                p.i + 3 <= length(p.s) || throw(JSONError("bad \\u escape", p.i))
                hex = String(p.s[p.i:p.i+3]); p.i += 4
                cp = parse(UInt32, hex, base=16)
                if 0xD800 <= cp <= 0xDBFF   # surrogate pair
                    (peek(p) == UInt8('\\') && p.i + 5 <= length(p.s) && p.s[p.i+1] == UInt8('u')) ||
                        throw(JSONError("lone high surrogate", p.i))
                    lo = parse(UInt32, String(p.s[p.i+2:p.i+5]), base=16); p.i += 6
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                end
                write(io, Char(cp))
            else
                throw(JSONError("bad escape", p.i))
            end
        else
            write(io, c); p.i += 1
        end
    end
end

function parse_array(p::Parser)
    expect(p, UInt8('['))
    out = Any[]
    skipws(p)
    if peek(p) == UInt8(']'); p.i += 1; return out; end
    while true
        push!(out, parse_value(p))
        skipws(p)
        c = peek(p); p.i += 1
        c == UInt8(',') && continue
        c == UInt8(']') && return out
        throw(JSONError("expected ',' or ']'", p.i - 1))
    end
end

function parse_object(p::Parser)
    expect(p, UInt8('{'))
    out = Dict{String,Any}()
    skipws(p)
    if peek(p) == UInt8('}'); p.i += 1; return out; end
    while true
        skipws(p)
        k = parse_string(p)
        skipws(p); expect(p, UInt8(':'))
        out[k] = parse_value(p)
        skipws(p)
        c = peek(p); p.i += 1
        c == UInt8(',') && continue
        c == UInt8('}') && return out
        throw(JSONError("expected ',' or '}'", p.i - 1))
    end
end

end # module JSON
