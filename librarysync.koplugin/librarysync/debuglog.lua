-- Debug log: plain text lines appended to a file as things happen, so they survive a crash,
-- and the "Save debug log" report (plugin log, KOReader crash.log tail, version, settings with
-- passwords and tokens hidden). No KOReader dependencies.
local M = {}

M.path = nil          -- set by the plugin (settings folder/librarysync_debug.log)
M.MAX = 256 * 1024    -- trimmed to the newest half once bigger than this

local function readAll(path)
    local f = path and io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

--- The last max_bytes of a file (starting at a full line), or nil when it cannot be read.
function M.tail(path, max_bytes)
    local f = path and io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end") or 0
    local from = math.max(0, size - (max_bytes or 16384))
    f:seek("set", from)
    local d = f:read("*a") or ""
    f:close()
    if from > 0 then d = d:gsub("^[^\n]*\n", "", 1) end
    return d
end

--- Append one line (opened, written and closed each time: nothing is lost if KOReader dies next).
function M.write(...)
    if not M.path then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    pcall(function()
        local f = io.open(M.path, "ab")
        if not f then return end
        f:write(os.date("%Y-%m-%d %H:%M:%S "), (table.concat(parts, " "):gsub("\n", " | ")), "\n")
        local size = f:seek("end") or 0
        f:close()
        if size > M.MAX then
            local keep = M.tail(M.path, math.floor(M.MAX / 2)) or ""
            local w = io.open(M.path, "wb")
            if w then w:write(keep) w:close() end
        end
    end)
end

local SECRET = { password = true, token = true, api_key = true, apikey = true, key = true, secret = true }

local function secretKey(k)
    k = tostring(k):lower()
    return SECRET[k] or k:find("password", 1, true) or k:find("token", 1, true) or k:find("secret", 1, true)
end

--- A copy of the settings as text, one per line, sorted; passwords and tokens hidden.
function M.settings_text(settings)
    local keys = {}
    for k in pairs(settings or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    local function show(v, depth)
        if type(v) ~= "table" then
            return type(v) == "string" and string.format("%q", v) or tostring(v)
        end
        if depth > 2 then return "{…}" end
        local items, n = {}, 0
        for k2, v2 in pairs(v) do
            n = n + 1
            if n > 20 then items[#items + 1] = "…" break end
            items[#items + 1] = tostring(k2) .. "=" .. (secretKey(k2) and "(hidden)" or show(v2, depth + 1))
        end
        return "{" .. table.concat(items, ", ") .. "}"
    end
    for _, k in ipairs(keys) do
        local v = settings[k]
        if secretKey(k) then
            v = (v == nil or v == "") and "(empty)" or "(set, hidden)"
        else
            v = show(v, 1)
        end
        out[#out + 1] = tostring(k) .. " = " .. v
    end
    return table.concat(out, "\n")
end

--- Hide anything that looks like a password or token in free text (e.g. a URL with user:pass@).
function M.scrub(text, secrets)
    text = tostring(text or "")
    text = text:gsub("(https?://)[^/@%s]+:[^/@%s]+@", "%1(hidden)@")
    text = text:gsub("(Authorization[\"']?%s*[:=]%s*[\"']?)[^\n\"']+", "%1(hidden)")
    for _, s in ipairs(secrets or {}) do
        if type(s) == "string" and #s >= 3 then
            text = text:gsub(s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"), "(hidden)")
        end
    end
    return text
end

--- Build the report. opts: version, device, settings (table), crash_paths (list), secrets (list),
-- extra (list of lines about the plugin's state).
function M.report(opts)
    opts = opts or {}
    local out = {
        "Library sync debug log",
        "Saved: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "Plugin version: " .. tostring(opts.version or "?"),
    }
    if opts.device then out[#out + 1] = "Device: " .. tostring(opts.device) end
    out[#out + 1] = ""
    out[#out + 1] = "== Settings (passwords and tokens hidden) =="
    out[#out + 1] = M.settings_text(opts.settings)
    if opts.extra and #opts.extra > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "== State =="
        for _, l in ipairs(opts.extra) do out[#out + 1] = tostring(l) end
    end
    out[#out + 1] = ""
    out[#out + 1] = "== Plugin log (newest last) =="
    out[#out + 1] = M.tail(M.path, 64 * 1024) or "(empty)"
    for _, p in ipairs(opts.crash_paths or {}) do
        local t = M.tail(p, 32 * 1024)
        if t then
            out[#out + 1] = ""
            out[#out + 1] = "== " .. p .. " (last part) =="
            out[#out + 1] = t
            break
        end
    end
    return M.scrub(table.concat(out, "\n"), opts.secrets)
end

--- Write the report to path. Returns true or nil, error.
function M.save(path, opts)
    local text = M.report(opts)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(text, "\n")
    f:close()
    return true
end

M._readAll = readAll
return M
