-- Update notifier: is there a newer release of this plugin on GitHub? Asked at most once a day,
-- at the end of a sync (the device is online then anyway) or when you ask. Nothing is installed:
-- the plugin says which version is out and what changed (install it with Storefront, or copy
-- the zip). Saved in cfg.update_path as { latest=, name=, url=, notes=, zip=, published=,
-- checked_at=, error= }. No KOReader dependencies.
local ltn12 = require("ltn12")
local json = require("librarysync/json")

local M = {}

M.REPO = "gkgsiva/koirc"
M.API = "https://api.github.com/repos/" .. M.REPO .. "/releases/latest"
M.PAGE = "https://github.com/" .. M.REPO .. "/releases/latest"
M.EVERY = 86400

--- "v2.10.1" -> { 2, 10, 1 } (nil when there is no number).
function M.parse(v)
    local out = {}
    for n in tostring(v or ""):gsub("^[vV]", ""):gmatch("(%d+)") do out[#out + 1] = tonumber(n) end
    if #out == 0 then return nil end
    return out
end

--- Is version a newer than b? ("v2.10" > "2.9", "2.7.1" > "2.7")
function M.newer(a, b)
    local x, y = M.parse(a), M.parse(b)
    if not x then return false end
    if not y then return true end
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

--- Due for a check? saved: the update file; now: os.time().
function M.due(saved, now)
    return not (saved and saved.checked_at and (now or os.time()) - saved.checked_at < M.EVERY)
end

--- The latest release, from GitHub's API. transport(url, headers, sink) -> code, headers.
-- Returns { latest=, name=, url=, notes=, zip=, published= } or nil, error.
function M.fetch(transport)
    local out = {}
    local code, err = transport(M.API, {
        ["User-Agent"] = "KOReader-LibrarySync", ["Accept"] = "application/vnd.github+json",
    }, ltn12.sink.table(out))
    if not code then return nil, tostring(err) end
    if code == 404 then return nil, "no release published yet" end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    local v = json.decode(table.concat(out))
    if type(v) ~= "table" or not v.tag_name then return nil, "unexpected answer from GitHub" end
    local zip
    for _, a in ipairs(type(v.assets) == "table" and v.assets or {}) do
        if type(a) == "table" and tostring(a.name or ""):match("%.zip$") then zip = a.browser_download_url break end
    end
    local notes = tostring(v.body or ""):gsub("\r", "")
    if #notes > 3000 then notes = notes:sub(1, 3000) .. "…" end
    return { latest = tostring(v.tag_name), name = v.name, url = v.html_url or M.PAGE, notes = notes,
             zip = zip, published = v.published_at }
end

--- Check and save the answer (errors are saved too, so a failing check waits a day as well).
-- Returns the saved table.
function M.check(cfg, transport, now)
    local util = require("librarysync/util")
    local info, err = M.fetch(transport)
    local saved = (cfg.update_path and util.load_table(cfg.update_path)) or {}
    if info then
        for k, v in pairs(info) do saved[k] = v end
        saved.error = nil
    else
        saved.error = err
    end
    saved.checked_at = now or os.time()
    if cfg.update_path then util.save_table(cfg.update_path, saved) end
    return saved
end

--- The release text, short enough to read on an e-reader: markdown marks taken out.
function M.plain(notes)
    local s = tostring(notes or "")
    s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("`", ""):gsub("\n#+%s*", "\n"):gsub("^#+%s*", "")
    s = s:gsub("\n%* ", "\n• "):gsub("^%* ", "• ")
    s = s:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
    return s
end

return M
