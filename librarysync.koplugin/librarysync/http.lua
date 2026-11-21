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

function M.get(url, headers, sink)
    local http = url:match("^https") and require("ssl.https") or require("socket.http")
    local socketutil_ok, socketutil = pcall(require, "socketutil")
    if socketutil_ok then socketutil:set_timeout(30, 3600) end
    local ok, code, hdrs = pcall(function()
        local _, c, h = http.request{ url = url, method = "GET", headers = headers, sink = sink, redirect = true }
        return c, h
    end)
    if socketutil_ok then socketutil:reset_timeout() end
    if not ok then return nil, tostring(code) end
    if type(code) ~= "number" then return nil, tostring(code) end
    return code, hdrs or {}
end

return M
