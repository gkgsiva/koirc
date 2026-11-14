--[[--
What the plugin learns from use:
- Bot health: how often each bot sent the book, how long it took to start
  and how fast the transfer was. Reliable, fast bots are tried first (with
  smart retry in koirc/retry.lua).
- Picks: the formats and bots the user chooses by hand. The ★ best match
  leans toward them.

Old counts fade (they are halved when they grow large), so a bot that got
better or worse is noticed. The data is a plain table, saved by the caller.

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local M = {}

-- Halve a bot's counts once it has this many results.
M.FADE_AT = 40
-- Picks needed before they change the ★ best match.
M.MIN_PICKS = 3
-- Bots remembered at most (least used are dropped).
M.MAX_BOTS = 150

-- Failures that say the bot is unreliable. Interrupted transfers (our Wi-Fi)
-- and files a bot doesn't have say nothing about the bot.
local BAD = { offline = true, no_reply = true, stalled = true, timeout = true, transfer = true }

local Health = {}
Health.__index = Health

--- data: saved table (or nil); now(): seconds.
function M.new(data, now)
    local self = setmetatable({}, Health)
    self.data = type(data) == "table" and data or {}
    self.data.bots = type(self.data.bots) == "table" and self.data.bots or {}
    self.data.formats = type(self.data.formats) == "table" and self.data.formats or {}
    self.data.picks = type(self.data.picks) == "table" and self.data.picks or {}
    self.now = now or os.time
    return self
end

local function key(bot) return tostring(bot or ""):lower() end

function Health:bot(bot, create)
    local k = key(bot)
    if k == "" then return nil end
    local b = self.data.bots[k]
    if not b and create then
        b = { name = tostring(bot), ok = 0, fail = 0, bytes = 0, secs = 0, wait = 0, waits = 0 }
        self.data.bots[k] = b
        self:trim()
    end
    return b
end

function Health:trim()
    local n, oldest, oldest_k = 0, nil, nil
    for k, b in pairs(self.data.bots) do
        n = n + 1
        if not oldest or (b.last or 0) < oldest then oldest, oldest_k = b.last or 0, k end
    end
    if n > M.MAX_BOTS and oldest_k then self.data.bots[oldest_k] = nil end
end

local function fade(b)
    if b.ok + b.fail < M.FADE_AT then return end
    b.ok, b.fail = b.ok / 2, b.fail / 2
    b.bytes, b.secs = b.bytes / 2, b.secs / 2
    b.wait, b.waits = b.wait / 2, b.waits / 2
end

--- A download finished: info = {bot, ok, reason, bytes, secs, wait}.
-- Returns true when something was recorded.
function Health:record(info)
    if type(info) ~= "table" or not info.bot then return false end
    if not info.ok and not BAD[info.reason or ""] then return false end
    local b = self:bot(info.bot, true)
    b.name = tostring(info.bot)
    b.last = self.now()
    if info.ok then
        b.ok = b.ok + 1
        local bytes, secs = tonumber(info.bytes), tonumber(info.secs)
        if bytes and secs and bytes > 0 and secs > 0 then
            b.bytes = b.bytes + bytes
            b.secs = b.secs + secs
        end
        local wait = tonumber(info.wait)
        if wait and wait >= 0 then
            b.wait = b.wait + wait
            b.waits = b.waits + 1
        end
    else
        b.fail = b.fail + 1
    end
    fade(b)
    return true
end

--- Share of downloads the bot sent (0..1), with a neutral start of 0.5 for
-- bots not seen yet.
function Health:reliability(bot)
    local b = self:bot(bot)
    if not b then return 0.5 end
    return (b.ok + 1) / (b.ok + b.fail + 2)
end

--- Average transfer speed in bytes per second, or nil.
function Health:speed(bot)
    local b = self:bot(bot)
    if not b or b.secs <= 0 then return nil end
    return b.bytes / b.secs
end

--- Average seconds before the bot started sending, or nil.
function Health:waitTime(bot)
    local b = self:bot(bot)
    if not b or b.waits <= 0 then return nil end
    return b.wait / b.waits
end

--- Higher is better; 50 for a bot not seen yet.
function Health:score(bot)
    local score = self:reliability(bot) * 100
    local speed = self:speed(bot)
    if speed then score = score + math.min(speed / 51200, 10) end -- up to 10 for 500 KB/s
    local wait = self:waitTime(bot)
    if wait then score = score - math.min(wait / 30, 10) end -- up to -10 for 5 min
    return score
end

--- The user chose this result by hand.
function Health:recordPick(ext, bot)
    if ext and ext ~= "" then
        local f = self.data.formats
        f[ext] = (f[ext] or 0) + 1
        local total = 0
        for _, n in pairs(f) do total = total + n end
        if total > M.FADE_AT then
            for k, n in pairs(f) do f[k] = n / 2 end
        end
    end
    local k = key(bot)
    if k ~= "" then
        local p = self.data.picks
        p[k] = (p[k] or 0) + 1
        if p[k] > M.FADE_AT then
            for b, n in pairs(p) do p[b] = n / 2 end
        end
    end
end

--- Share of the user's picks in this format (0..1), or 0 with too few picks.
function Health:formatShare(ext)
    local f = self.data.formats
    local total = 0
    for _, n in pairs(f) do total = total + n end
    if total < M.MIN_PICKS or not ext then return 0 end
    return (f[ext] or 0) / total
end

--- Rank for results (lower is better), to use instead of the plain
-- preferred-format position: formats the user keeps picking move up, and
-- among equal formats healthy bots the user picks come first.
-- base: the preferred-format rank (results.formatRank).
function Health:rank(entry, base, ext)
    local r = base - self:formatShare(ext) * 1.5
    if base >= 1000 then return base end -- archives KOReader can't open stay last
    local picks = self.data.picks[key(entry.bot)] or 0
    -- Small: only breaks ties between results of the same format.
    local bonus = math.min(picks, 5) * 0.02 + (self:score(entry.bot) - 50) / 1000
    return r - bonus
end

--- Lines for a "Bot health" screen, best first.
function Health:report(max)
    local list = {}
    for _, b in pairs(self.data.bots) do list[#list + 1] = b end
    table.sort(list, function(a, b) return self:score(a.name) > self:score(b.name) end)
    local out = {}
    for i = 1, math.min(#list, max or 20) do
        local b = list[i]
        local speed = self:speed(b.name)
        local wait = self:waitTime(b.name)
        out[#out + 1] = {
            name = b.name,
            ok = math.floor(b.ok + 0.5),
            fail = math.floor(b.fail + 0.5),
            reliability = self:reliability(b.name),
            speed = speed,
            wait = wait,
        }
    end
    return out
end

return M
