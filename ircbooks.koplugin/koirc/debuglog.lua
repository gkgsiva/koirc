--[[--
A small in-memory log of what the plugin did (IRC lines, Hardcover requests,
warnings), kept for "Save log" so it can be shared when something goes wrong
on a real device. Keeps the last MAX lines; nothing is written to disk until
the user saves it.

No KOReader dependencies.
]]

local M = {}

M.MAX = 600

local lines, first = {}, 1

local function stringify(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        local v = select(i, ...)
        parts[#parts + 1] = type(v) == "table" and "<table>" or tostring(v)
    end
    return table.concat(parts, " ")
end

--- Hide secrets that may appear in IRC or HTTP lines.
function M.redact(s)
    s = s:gsub("([Bb]earer%s+)[%w%-%._~%+/=]+", "%1••••")
    s = s:gsub("^([<>]?%s*PASS%s+).*", "%1••••")
    s = s:gsub("(ircbooks:%s+[<>]%s*PASS%s+).*", "%1••••")
    s = s:gsub("(NickServ%s+:?IDENTIFY%s+).*", "%1••••")
    return s
end

function M.add(level, ...)
    local line = os.date("%H:%M:%S ") .. (level or "") .. " " .. M.redact(stringify(...))
    lines[#lines + 1] = line
    if #lines - first + 1 > M.MAX then
        lines[first] = nil
        first = first + 1
    end
end

function M.lines()
    local out = {}
    for i = first, #lines do out[#out + 1] = lines[i] end
    return out
end

function M.clear()
    lines, first = {}, 1
end

--- A logger that records into this log and forwards to the real one.
function M.wrap(logger)
    local proxy = {}
    for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
        proxy[level] = function(...)
            M.add(level, ...)
            local f = logger and logger[level]
            if f then return f(...) end
        end
    end
    return setmetatable(proxy, { __index = logger })
end

local SECRET_KEYS = { password = true, hardcover_token = true }
-- Large or private data that does not help with debugging.
local SKIP_KEYS = {
    hardcover_cache = true, hardcover_files = true, search_history = true,
    hardcover_known = true, hardcover_progress_sent = true, hardcover_status_sent = true,
}

--- Settings as text, with secrets hidden and big tables summarised.
function M.settingsText(settings)
    local keys = {}
    for k in pairs(settings or {}) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local v = settings[k]
        if SECRET_KEYS[k] then
            v = (v and v ~= "") and "(set)" or "(not set)"
        elseif SKIP_KEYS[k] or type(v) == "table" then
            local n = 0
            if type(v) == "table" then for _ in pairs(v) do n = n + 1 end end
            v = string.format("<%d entries>", n)
        else
            v = tostring(v)
        end
        out[#out + 1] = "  " .. k .. " = " .. v
    end
    return table.concat(out, "\n")
end

--- Lines mentioning the plugin in the last part of KOReader's crash.log.
function M.crashLogLines(path, max_lines)
    local f = path and io.open(path, "rb")
    if not f then return {} end
    local size = f:seek("end") or 0
    -- Only the last 512 KB: crash.log can be large.
    f:seek("set", math.max(0, size - 524288))
    local data = f:read("*a") or ""
    f:close()
    local out = {}
    for line in data:gmatch("[^\n]+") do
        if line:find("ircbooks", 1, true) then out[#out + 1] = M.redact(line) end
    end
    max_lines = max_lines or 300
    if #out > max_lines then
        local trimmed = {}
        for i = #out - max_lines + 1, #out do trimmed[#trimmed + 1] = out[i] end
        out = trimmed
    end
    return out
end

--- The whole report. info: {header lines}, settings, crash_log path.
function M.report(info)
    local parts = {}
    parts[#parts + 1] = "IRC book search (ircbooks.koplugin) debug log"
    parts[#parts + 1] = "Saved " .. os.date("%Y-%m-%d %H:%M:%S")
    for _, l in ipairs(info.header or {}) do parts[#parts + 1] = l end
    parts[#parts + 1] = ""
    parts[#parts + 1] = "Settings:"
    parts[#parts + 1] = M.settingsText(info.settings)
    parts[#parts + 1] = ""
    parts[#parts + 1] = "Plugin log (this session):"
    local own = M.lines()
    if #own == 0 then parts[#parts + 1] = "  (empty)" end
    for _, l in ipairs(own) do parts[#parts + 1] = l end
    parts[#parts + 1] = ""
    parts[#parts + 1] = "crash.log lines about the plugin:"
    local cl = M.crashLogLines(info.crash_log)
    if #cl == 0 then parts[#parts + 1] = "  (none found)" end
    for _, l in ipairs(cl) do parts[#parts + 1] = l end
    return table.concat(parts, "\n") .. "\n"
end

return M
