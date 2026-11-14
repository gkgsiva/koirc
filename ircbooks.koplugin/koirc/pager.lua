--[[--
How the plugin's lists refresh the e-ink screen when you turn a page.

Kept free of KOReader modules so it can be tested on a computer.
]]

local M = {}

-- A cleaner (slower) refresh every this many page turns, to clear the
-- faint ghosting fast refreshes leave behind.
M.CLEANUP_EVERY = 6

--- The refresh to use for page turn number n (1, 2, ...) of a list.
-- fast: true for quick e-ink page turns (default), false for KOReader's
-- normal "ui" refresh on every turn. every: cleanup interval (0 = never).
function M.turnMode(n, fast, every)
    if fast == false then return "ui" end
    every = tonumber(every) or M.CLEANUP_EVERY
    if every > 0 and n > 0 and n % every == 0 then return "partial" end
    return "fast"
end

--- True when turning to `page` would show exactly what is on screen now
-- (e.g. a swipe on a list with a single page), so nothing needs redrawing.
function M.isNoop(current, page, page_num)
    return page == current and (page_num or 1) <= 1
end

--- Strips of the screen (w x h) not covered by rect {x, y, w, h}, as
-- {x, y, w, h} tables. Empty when rect covers the whole screen.
function M.uncovered(w, h, rect)
    if not rect then return {{ x = 0, y = 0, w = w, h = h }} end
    local x0, y0 = math.max(0, rect.x or 0), math.max(0, rect.y or 0)
    local x1, y1 = math.min(w, x0 + (rect.w or 0)), math.min(h, y0 + (rect.h or 0))
    if x1 <= x0 or y1 <= y0 then return {{ x = 0, y = 0, w = w, h = h }} end
    local out = {}
    if y0 > 0 then out[#out + 1] = { x = 0, y = 0, w = w, h = y0 } end
    if y1 < h then out[#out + 1] = { x = 0, y = y1, w = w, h = h - y1 } end
    if x0 > 0 then out[#out + 1] = { x = 0, y = y0, w = x0, h = y1 - y0 } end
    if x1 < w then out[#out + 1] = { x = x1, y = y0, w = w - x1, h = y1 - y0 } end
    return out
end

--- A small "has this changed?" memo that forgets everything after ttl
-- seconds or when its stamp changes. now: function returning seconds.
function M.memo(ttl, now)
    local m = { ttl = ttl, now = now or os.time, data = {}, stamp = nil, made = nil }
    function m:get(stamp)
        local t = self.now()
        if self.stamp ~= stamp or not self.made or t - self.made > self.ttl then
            self.data, self.stamp, self.made = {}, stamp, t
        end
        return self.data
    end
    function m:clear() self.data, self.made = {}, nil end
    return m
end

return M
