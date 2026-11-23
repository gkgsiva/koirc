-- HTTP transport: get(url, headers, sink) -> code, response_headers (or nil, err).
-- Kept separate so the sync logic can be tested with a fake.
local ltn12 = require("ltn12")
local M = {}

function M.auth_headers(cfg)
    local h = { ["User-Agent"] = "KOReader-LibrarySync" }
    if cfg.auth == "bearer" then
        if cfg.token and cfg.token ~= "" then h.Authorization = "Bearer " .. cfg.token end
    else
        local mime = require("mime")
        h.Authorization = "Basic " .. mime.b64((cfg.username or "") .. ":" .. (cfg.password or ""))
    end
    return h
end

-- LuaSec's https.request refuses any request that sets `redirect` ("redirect not supported"), so
-- every https address failed before v2.5.3. KOReader's LuaSocket handles https itself (through
-- LuaSec) and follows redirects; LuaSec is used directly only when that LuaSocket is too old.
local function request(url, params)
    local socket_http = require("socket.http")
    params.url = url
    params.redirect = true
    local ok, r1, c, h = pcall(socket_http.request, params)
    if ok and type(c) == "number" then return c, h end
    local err = ok and (c or r1) or r1
    if url:match("^https") and tostring(err):lower():find("scheme", 1, true) then
        local https = require("ssl.https")
        params.redirect = nil
        ok, r1, c, h = pcall(https.request, params)
        if ok and type(c) == "number" then return c, h end
        err = ok and (c or r1) or r1
    end
    return nil, tostring(err)
end
M._request = request

function M.get(url, headers, sink)
    local socketutil_ok, socketutil = pcall(require, "socketutil")
    if socketutil_ok then socketutil:set_timeout(30, 3600) end
    local code, hdrs = request(url, { method = "GET", headers = headers, sink = sink })
    if socketutil_ok then socketutil:reset_timeout() end
    if not code then return nil, hdrs end
    return code, hdrs or {}
end

--- Send a request with a body (JSON for the Library API). Returns code, response body (or nil, err).
function M.send(method, url, headers, body)
    local socketutil_ok, socketutil = pcall(require, "socketutil")
    if socketutil_ok then socketutil:set_timeout(15, 60) end
    local h = {}
    for k, v in pairs(headers or {}) do h[k] = v end
    h["Content-Type"] = "application/json"
    h["Content-Length"] = tostring(#body)
    local out = {}
    local code, err = request(url, { method = method, headers = h,
        source = ltn12.source.string(body), sink = ltn12.sink.table(out) })
    if socketutil_ok then socketutil:reset_timeout() end
    if not code then return nil, err end
    return code, table.concat(out)
end

return M
