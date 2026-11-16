--[[--
When background downloads may run: only in set hours (for example at
night), only while Wi-Fi is already on (the plugin does not turn it on for
them), and only while charging. Each rule is off unless set.

Settings: queue_hours = { from = 22, to = 7 } (hours, 0-23; from == to or
nil means any time), queue_wifi_only, queue_charging_only.

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local M = {}

-- How often a waiting queue looks again (seconds).
M.CHECK_EVERY = 300

M.HOUR_CHOICES = {
    { from = 22, to = 7 }, { from = 23, to = 6 }, { from = 0, to = 6 },
    { from = 1, to = 5 }, { from = 9, to = 17 }, { from = 18, to = 23 },
}

local function hours(s)
    local h = type(s) == "table" and s.queue_hours
    if type(h) ~= "table" then return nil end
    local from, to = tonumber(h.from), tonumber(h.to)
    if not from or not to or from == to then return nil end
    return math.floor(from) % 24, math.floor(to) % 24
end

--- "22:00–07:00".
function M.hoursText(from, to)
    return string.format("%02d:00–%02d:00", from, to)
end

--- Is hour h (0-23) in the window from..to (which may cross midnight)?
function M.inWindow(h, from, to)
    if from == to then return true end
    if from < to then return h >= from and h < to end
    return h >= from or h < to
end

--- Seconds from now until the window opens (0 when open).
function M.untilOpen(now, from, to, date)
    date = date or os.date
    local t = date("*t", now)
    if M.inWindow(t.hour, from, to) then return 0 end
    local wait = ((from - t.hour) % 24) * 3600 - (t.min or 0) * 60 - (t.sec or 0)
    if wait <= 0 then wait = wait + 86400 end
    return wait
end

--- Short description of the rules that are set, or nil when none are.
function M.describe(s)
    local parts = {}
    local from, to = hours(s)
    if from then parts[#parts + 1] = M.hoursText(from, to) end
    if s and s.queue_wifi_only then parts[#parts + 1] = "Wi-Fi already on" end
    if s and s.queue_charging_only then parts[#parts + 1] = "charging" end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

--- May background downloads run now? env: now (seconds), wifi() -> bool
-- or nil (unknown counts as yes), charging() -> bool or nil, date (os.date).
-- Returns true, or false and the reason ("hours", "wifi", "charging") with
-- the seconds until the window opens for "hours".
function M.allowed(s, env)
    env = env or {}
    local from, to = hours(s)
    if from then
        local wait = M.untilOpen(env.now or os.time(), from, to, env.date)
        if wait > 0 then return false, "hours", wait end
    end
    if s and s.queue_wifi_only and env.wifi and env.wifi() == false then return false, "wifi" end
    if s and s.queue_charging_only and env.charging and env.charging() == false then return false, "charging" end
    return true
end

return M
