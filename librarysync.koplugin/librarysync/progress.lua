--[[--
Sync progress: books done and still to go, bytes, the book being downloaded, speed and time
left. Pure Lua (no KOReader dependencies).

sync.run keeps one tracker; the background process saves tracker:snapshot() to a file about
once a second, and the status screen formats it with M.format / M.short.
]]

local M = {}

local WINDOW = 20  -- seconds of samples behind the speed shown

local Tracker = {}
Tracker.__index = Tracker

--- now: function returning seconds (default os.time).
function M.new(now)
    now = now or os.time
    return setmetatable({
        now = now, started = now(), phase = nil, downloading = false,
        books_total = 0, books_done = 0, failed = 0,
        bytes_total = 0, unknown_size = 0, bytes_done = 0,
        current = nil, cur_bytes = 0, cur_size = nil,
        samples = {},
    }, Tracker)
end

--- What the sync is doing besides downloading ("Reading the catalog"…).
function Tracker:setPhase(text)
    if not self.downloading then self.phase = text end
end

--- The books that will be downloaded: list of { size = bytes or nil }.
function Tracker:plan(list)
    self.books_total, self.bytes_total, self.unknown_size = 0, 0, 0
    for _, it in ipairs(list) do
        self.books_total = self.books_total + 1
        if it.size and it.size > 0 then self.bytes_total = self.bytes_total + it.size
        else self.unknown_size = self.unknown_size + 1 end
    end
    self.downloading = true
    self.phase = nil
    self.started_dl = self.now()
    self:sample()
end

function Tracker:sample()
    local t = self.now()
    local total = self.bytes_done + self.cur_bytes
    local s = self.samples
    local last = s[#s]
    if last and last.t == t then last.b = total
    else s[#s + 1] = { t = t, b = total } end
    while #s > 2 and s[1].t < t - WINDOW do table.remove(s, 1) end
end

function Tracker:begin(name, size)
    self.current, self.cur_size, self.cur_bytes = name, size, 0
    self:sample()
end

--- n: bytes of the current book received so far.
function Tracker:bytes(n)
    self.cur_bytes = n or 0
    self:sample()
end

--- The current book ended. ok: downloaded; size: its bytes (what was received when nil).
function Tracker:finish(ok, size)
    if ok then
        self.books_done = self.books_done + 1
        self.bytes_done = self.bytes_done + (size or self.cur_bytes or 0)
    else
        self.failed = self.failed + 1
        -- what a failed book was expected to weigh no longer counts as left to do
        if self.cur_size and self.cur_size > 0 then
            self.bytes_total = math.max(0, self.bytes_total - self.cur_size)
        end
    end
    self.current, self.cur_size, self.cur_bytes = nil, nil, 0
    self:sample()
end

--- A downloaded book that was already there (copied, nothing fetched).
function Tracker:skip(size)
    self.books_done = self.books_done + 1
    if size and size > 0 then self.bytes_total = math.max(0, self.bytes_total - size) end
end

function Tracker:doneDownloading()
    self.downloading = false
    self.current = nil
end

--- Bytes per second over the last WINDOW seconds (nil until there is something to measure).
function Tracker:speed()
    local s = self.samples
    if #s < 2 then return nil end
    local a, b = s[1], s[#s]
    local dt = b.t - a.t
    if dt < 2 then return nil end
    return math.max(0, (b.b - a.b) / dt)
end

--- A plain table with everything the status screen shows.
function Tracker:snapshot()
    local now = self.now()
    local got = self.bytes_done + self.cur_bytes
    local speed = self:speed()
    local left = nil
    if self.downloading and speed and speed > 0 then
        local remaining = math.max(0, self.bytes_total - got)
        if self.unknown_size > 0 and self.books_done > 0 then
            -- books without a known size: count them as an average book
            remaining = remaining + self.unknown_size * (self.bytes_done / self.books_done)
        end
        left = math.floor(remaining / speed + 0.5)
    end
    return {
        phase = self.phase, downloading = self.downloading or nil,
        books_done = self.books_done, books_total = self.books_total, failed = self.failed,
        bytes_done = got, bytes_total = self.bytes_total, unknown_size = self.unknown_size,
        current = self.current, cur_bytes = self.cur_bytes, cur_size = self.cur_size,
        speed = speed, eta = left, elapsed = now - self.started, at = now,
    }
end

local function mb(n)
    n = n or 0
    if n >= 1073741824 then return string.format("%.1f GB", n / 1073741824) end
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%d KB", math.floor(n / 1024 + 0.5))
end
M.mb = mb

--- "1 h 05 min", "4 min 10 s", "35 s".
function M.duration(s)
    s = math.max(0, math.floor((s or 0) + 0.5))
    if s >= 3600 then return string.format("%d h %02d min", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
    if s >= 60 then return string.format("%d min %02d s", math.floor(s / 60), s % 60) end
    return string.format("%d s", s)
end

function M.speed(bps)
    if not bps then return nil end
    if bps >= 1048576 then return string.format("%.1f MB/s", bps / 1048576) end
    return string.format("%d KB/s", math.floor(bps / 1024 + 0.5))
end

--- The books still to go (not done, not failed).
local function pending(s)
    return math.max(0, (s.books_total or 0) - (s.books_done or 0) - (s.failed or 0))
end
M.pending = pending

M.DEFAULT_SPEED = 512 * 1024  -- a guess for the first sync, before any speed was measured

--- Seconds to download `bytes` (plus `unknown` books of unknown size, counted as an average
-- book of the others, or 2 MB) at `speed` bytes/s (nil: DEFAULT_SPEED).
function M.estimate(bytes, unknown, count, speed)
    bytes, unknown, count = bytes or 0, unknown or 0, count or 0
    local known = count - unknown
    local avg = known > 0 and bytes / known or 2 * 1048576
    return math.floor((bytes + unknown * avg) / (speed or M.DEFAULT_SPEED) + 0.5)
end

--- Measured speeds blended so one slow or fast sync does not swing the estimate too far.
function M.blend_speed(old, new)
    if not new or new <= 0 then return old end
    if not old or old <= 0 then return new end
    return 0.6 * new + 0.4 * old
end

--- "about 6 min" (with the speed it assumes). tr: translate function (optional).
function M.estimate_text(bytes, unknown, count, speed, tr)
    tr = tr or function(x) return x end
    local secs = M.estimate(bytes, unknown, count, speed)
    if speed then
        return string.format(tr("about %s at your recent speed (%s)"), M.duration(secs), M.speed(speed))
    end
    return string.format(tr("roughly %s (a guess: no speed measured yet)"), M.duration(secs))
end

--- One line for a menu item. tr: translate function (optional).
function M.short(s, tr)
    tr = tr or function(x) return x end
    if not s then return nil end
    if not s.downloading then return s.phase or tr("starting…") end
    local parts = { string.format(tr("%d of %d books"), (s.books_done or 0) + (s.failed or 0), s.books_total or 0) }
    if (s.bytes_total or 0) > 0 then
        parts[#parts + 1] = string.format("%d%%", math.min(100, math.floor(100 * (s.bytes_done or 0) / s.bytes_total)))
    end
    if s.eta then parts[#parts + 1] = string.format(tr("%s left"), M.duration(s.eta)) end
    return table.concat(parts, " · ")
end

--- The whole status, several lines. tr: translate function (optional).
function M.format(s, tr)
    tr = tr or function(x) return x end
    if not s then return tr("Starting…") end
    local lines = {}
    if not s.downloading then
        lines[#lines + 1] = s.phase or tr("Starting…")
        if (s.books_done or 0) > 0 then
            lines[#lines + 1] = string.format(tr("Downloaded: %d books (%s)"), s.books_done, mb(s.bytes_done))
        end
        lines[#lines + 1] = string.format(tr("Running for %s"), M.duration(s.elapsed))
        return table.concat(lines, "\n")
    end
    lines[#lines + 1] = string.format(tr("Books: %d done · %d to go%s"), s.books_done or 0, pending(s),
        (s.failed or 0) > 0 and string.format(tr(" · %d failed"), s.failed) or "")
    if (s.bytes_total or 0) > 0 then
        local pct = math.min(100, math.floor(100 * (s.bytes_done or 0) / s.bytes_total))
        lines[#lines + 1] = string.format(tr("Size: %s of %s (%d%%)"), mb(s.bytes_done), mb(s.bytes_total), pct)
    else
        lines[#lines + 1] = string.format(tr("Size: %s so far"), mb(s.bytes_done))
    end
    if s.current then
        local cur = s.cur_size and s.cur_size > 0
            and string.format("%s of %s", mb(s.cur_bytes), mb(s.cur_size)) or mb(s.cur_bytes)
        lines[#lines + 1] = string.format(tr("Now: %s (%s)"), s.current, cur)
    end
    lines[#lines + 1] = string.format(tr("Speed: %s"), M.speed(s.speed) or tr("measuring…"))
    lines[#lines + 1] = string.format(tr("Time left: %s"), s.eta and string.format(tr("about %s"), M.duration(s.eta)) or tr("estimating…"))
    lines[#lines + 1] = string.format(tr("Running for %s"), M.duration(s.elapsed))
    return table.concat(lines, "\n")
end

return M
