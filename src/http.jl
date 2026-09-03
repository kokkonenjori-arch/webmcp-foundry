# http.jl — dependency-free HTTP/1.1 server and client over Sockets (stdlib).
#
# Scope: exactly what the Foundry host boundary needs — request-line + headers +
# Content-Length bodies, one response per connection (Connection: close), static
# files, JSON helpers, CORS, and a blocking loopback client used by the verifier
# so that the demo app is exercised as a genuine EXTERNAL oracle (over TCP), never
# by in-process function calls.

module Http

using Sockets

export Request, Response, serve!, stop!, request, static_response, json_response,
       text_response, urldecode, urlencode, parse_query, header, Server

struct Request
    method::String
    path::String            # path without query
    query::Dict{String,String}
    headers::Dict{String,String}   # lower-cased keys
    body::Vector{UInt8}
end

mutable struct Response
    status::Int
    headers::Vector{Pair{String,String}}
    body::Vector{UInt8}
end
Response(status::Int, ctype::String, body::AbstractString) =
    Response(status, ["Content-Type" => ctype], Vector{UInt8}(codeunits(body)))
Response(status::Int, ctype::String, body::Vector{UInt8}) =
    Response(status, ["Content-Type" => ctype], body)

header(r::Request, k::String, default="") = get(r.headers, lowercase(k), default)

const REASONS = Dict(200 => "OK", 201 => "Created", 204 => "No Content", 400 => "Bad Request",
    401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed",
    409 => "Conflict", 422 => "Unprocessable Entity", 500 => "Internal Server Error",
    503 => "Service Unavailable")

# ------------------------------------------------------------ url helpers

function urldecode(s::AbstractString)
    io = IOBuffer()
    bytes = codeunits(s)
    i = 1
    while i <= length(bytes)
        c = bytes[i]
        if c == UInt8('%') && i + 2 <= length(bytes)
            h = tryparse(UInt8, String(bytes[i+1:i+2]), base=16)
            if h === nothing
                write(io, c); i += 1
            else
                write(io, h); i += 3
            end
        elseif c == UInt8('+')
            write(io, ' '); i += 1
        else
            write(io, c); i += 1
        end
    end
    String(take!(io))
end

function urlencode(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(s)
        c = Char(b)
        if isletter(c) && b < 0x80 || isdigit(c) || c in ('-', '_', '.', '~')
            write(io, b)
        else
            write(io, '%', uppercase(string(b, base=16, pad=2)))
        end
    end
    String(take!(io))
end

function parse_query(q::AbstractString)
    d = Dict{String,String}()
    isempty(q) && return d
    for part in split(q, '&'; keepempty=false)
        kv = split(part, '='; limit=2)
        k = urldecode(kv[1])
        v = length(kv) == 2 ? urldecode(kv[2]) : ""
        d[k] = v
    end
    d
end

# ------------------------------------------------------------ parsing

function read_request(sock::IO)::Union{Request,Nothing}
    line = try readline(sock) catch; return nothing end
    isempty(line) && return nothing
    parts = split(strip(line), ' ')
    length(parts) >= 2 || return nothing
    method = String(parts[1]); target = String(parts[2])
    headers = Dict{String,String}()
    while true
        h = readline(sock)
        (isempty(h) || h == "\r") && break
        idx = findfirst(':', h)
        idx === nothing && continue
        headers[lowercase(strip(h[1:idx-1]))] = String(strip(h[idx+1:end]))
    end
    len = parse(Int, get(headers, "content-length", "0"))
    body = len > 0 ? read(sock, len) : UInt8[]
    qidx = findfirst('?', target)
    path = qidx === nothing ? target : target[1:qidx-1]
    query = qidx === nothing ? Dict{String,String}() : parse_query(target[qidx+1:end])
    Request(method, urldecode(path), query, headers, body)
end

function write_response(sock::IO, r::Response)
    reason = get(REASONS, r.status, "Status")
    io = IOBuffer()
    write(io, "HTTP/1.1 $(r.status) $reason\r\n")
    for (k, v) in r.headers
        write(io, "$k: $v\r\n")
    end
    write(io, "Content-Length: $(length(r.body))\r\nConnection: close\r\n\r\n")
    write(io, r.body)
    write(sock, take!(io))
    flush(sock)
end

# ------------------------------------------------------------ server

mutable struct Server
    port::Int
    handler::Function
    listener::Union{Sockets.TCPServer,Nothing}
    task::Union{Task,Nothing}
    running::Bool
end

"""
    serve!(handler, port) -> Server

Starts an HTTP server on 127.0.0.1:port in a background task. `handler(req)` must
return a `Response`. Exceptions in handlers become 500s with the message in the
body (never silently swallowed).
"""
function serve!(handler::Function, port::Int; host=Sockets.localhost)
    listener = listen(host, port)
    srv = Server(port, handler, listener, nothing, true)
    srv.task = @async begin
        while srv.running
            sock = try accept(listener) catch e; srv.running ? rethrow(e) : break end
            @async handle_conn(srv, sock)
        end
    end
    srv
end

function handle_conn(srv::Server, sock)
    try
        req = read_request(sock)
        req === nothing && (close(sock); return)
        resp = try
            srv.handler(req)
        catch e
            bt = catch_backtrace()
            msg = sprint(showerror, e, bt)
            Response(500, "text/plain; charset=utf-8", "handler error: " * msg)
        end
        write_response(sock, resp)
    catch e
        # connection-level failure: nothing sensible to do but close
    finally
        try close(sock) catch end
    end
end

function stop!(srv::Server)
    srv.running = false
    srv.listener === nothing || close(srv.listener)
    nothing
end

# ------------------------------------------------------------ response helpers

const MIME = Dict(".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8", ".json" => "application/json; charset=utf-8",
    ".svg" => "image/svg+xml", ".png" => "image/png", ".txt" => "text/plain; charset=utf-8",
    ".md" => "text/markdown; charset=utf-8", ".jl" => "text/plain; charset=utf-8")

function static_response(path::AbstractString)
    isfile(path) || return Response(404, "text/plain", "not found: $(basename(path))")
    ext = lowercase(splitext(path)[2])
    Response(200, get(MIME, ext, "application/octet-stream"), read(path))
end

json_response(status::Int, body::AbstractString) =
    Response(status, "application/json; charset=utf-8", body)
text_response(status::Int, body::AbstractString) =
    Response(status, "text/plain; charset=utf-8", body)

# ------------------------------------------------------------ client (loopback oracle)

"""
    request(method, host, port, path; body="", headers=[]) -> (status, headers, body::String)

Minimal blocking HTTP/1.1 client. Used by the verifier and the demo driver so the
app under test is always reached across the TCP boundary.
"""
function request(method::String, host::String, port::Int, path::String;
                 body::AbstractString="", headers::Vector{Pair{String,String}}=Pair{String,String}[])
    sock = connect(host, port)
    try
        io = IOBuffer()
        write(io, "$method $path HTTP/1.1\r\nHost: $host:$port\r\nConnection: close\r\n")
        for (k, v) in headers
            write(io, "$k: $v\r\n")
        end
        bb = Vector{UInt8}(codeunits(body))
        write(io, "Content-Length: $(length(bb))\r\n\r\n")
        write(io, bb)
        write(sock, take!(io)); flush(sock)
        status_line = readline(sock)
        sp = split(status_line, ' ')
        status = length(sp) >= 2 ? parse(Int, sp[2]) : 0
        hdrs = Dict{String,String}()
        while true
            h = readline(sock)
            (isempty(h) || h == "\r") && break
            idx = findfirst(':', h)
            idx === nothing && continue
            hdrs[lowercase(strip(h[1:idx-1]))] = String(strip(h[idx+1:end]))
        end
        len = parse(Int, get(hdrs, "content-length", "-1"))
        data = len >= 0 ? read(sock, len) : read(sock)
        return (status, hdrs, String(data))
    finally
        close(sock)
    end
end

end # module Http
