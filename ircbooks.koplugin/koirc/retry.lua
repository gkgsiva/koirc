--[[--
Smart retry: remembers which bots recently failed (offline, no answer, a
stalled transfer) and orders the other copies of a book so the next try goes
to a bot that is in the channel and has not just failed.

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local M = {}

-- Forget a failed bot after this long; it may be back.
M.BAD_FOR = 20 * 60
-- Downloads tried for one book before giving up.
M.MAX_ATTEMPTS = 4
-- Seconds to wait for a bot's first answer before trying another one.
M.ACK_TIMEOUT = 150

-- Failures that say something about the bot (not about the one file).
local BOT_REASONS = { offline = true, no_reply = true, stalled = true, timeout = true }

local Tracker = {}
Tracker.__index = Tracker

--- now(): seconds (defaults to os.time).
function M.new(now)
    return setmetatable({ bad = {}, now = now or os.time }, Tracker)
end

--- Remember a failed download from bot.
function Tracker:mark(bot, reason)
    if not bot or not BOT_REASONS[reason or ""] then return end
    self.bad[bot:lower()] = { at = self.now(), reason = reason }
end

--- Reason the bot failed recently, or nil.
function Tracker:isBad(bot)
    if not bot then return nil end
    local b = self.bad[bot:lower()]
    if not b then return nil end
    if self.now() - b.at > M.BAD_FOR then
        self.bad[bot:lower()] = nil
        return nil
    end
    return b.reason
end

--- Use bot health (koirc/bothealth.lua) to put reliable, fast bots first.
function Tracker:setHealth(health)
    self.health = health
end

-- Health scores are compared in steps of this size, so small differences
-- keep the order of the best matches.
local HEALTH_STEP = 15

--- Candidates in the order to try them: bots known to be in the channel
-- first, then unknown ones, then bots that failed recently; within each,
-- clearly healthier bots first. Bots known to be offline are left out.
-- Entries whose request is in tried are left out.
-- online(bot) returns true, false or nil (unknown); it may be nil.
function Tracker:order(list, tried, online)
    local scored = {}
    for i, e in ipairs(list or {}) do
        if not (tried and tried[e.request]) then
            local on = online and online(e.bot)
            if on ~= false then
                local rank = 1
                if on == true then rank = 0 end
                if self:isBad(e.bot) then rank = 2 end
                local h = self.health and math.floor(self.health:score(e.bot) / HEALTH_STEP) or 0
                scored[#scored + 1] = { e = e, r = rank, h = h, i = i }
            end
        end
    end
    table.sort(scored, function(a, b)
        if a.r ~= b.r then return a.r < b.r end
        if a.h ~= b.h then return a.h > b.h end
        return a.i < b.i
    end)
    local out = {}
    for k, s in ipairs(scored) do out[k] = s.e end
    return out
end

--- Short reason for messages, e.g. "offline".
function M.describe(reason)
    local names = {
        offline = "offline",
        no_reply = "no answer",
        refused = "file not available",
        stalled = "transfer stalled",
        transfer = "transfer failed",
        timeout = "too slow",
        disconnected = "disconnected",
    }
    return names[reason or ""] or "failed"
end

return M
