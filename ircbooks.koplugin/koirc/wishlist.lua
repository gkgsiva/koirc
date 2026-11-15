--[[--
Want to read auto-download: which books to queue after a sync, with a daily
cap and a pause switch. No KOReader dependencies (tested in spec/run.lua).

state (kept with the Hardcover data): {day = "2026-11-15", count = 3}, the
books queued on that day.
]]

local M = {}

-- Books queued per run.
M.PER_RUN = 5
-- Books queued per day unless changed in the settings. 0 = no limit.
M.DEFAULT_DAILY = 10
M.DAILY_CHOICES = { 3, 5, 10, 20, 0 }

function M.today(now)
    return os.date("%Y-%m-%d", now)
end

function M.dailyCap(settings)
    local cap = tonumber(settings.wishlist_daily_max)
    if cap == nil or cap < 0 then return M.DEFAULT_DAILY end
    return math.floor(cap)
end

--- Books queued today so far.
function M.countToday(state, now)
    if type(state) == "table" and state.day == M.today(now) then
        return tonumber(state.count) or 0
    end
    return 0
end

--- How many more books may be queued today (math.huge without a cap).
function M.left(state, now, cap)
    if not cap or cap <= 0 then return math.huge end
    return math.max(0, cap - M.countToday(state, now))
end

--- The state after queueing n more books.
function M.addToday(state, now, n)
    return { day = M.today(now), count = M.countToday(state, now) + n }
end

--- Books to queue now. opts:
--   has_file(book)   true when the book is on the device
--   tried            book id -> time last queued (updated for the picks)
--   now, retry_after seconds before a book not found is tried again
--   limit            at most this many (per run and what is left today)
function M.pick(books, opts)
    local pick = {}
    local limit = opts.limit or M.PER_RUN
    if limit <= 0 then return pick end
    local tried = opts.tried or {}
    for _i, b in ipairs(books or {}) do
        local id = tostring(b.id)
        if not opts.has_file(b) and opts.now - (tonumber(tried[id]) or 0) > (opts.retry_after or 0) then
            pick[#pick + 1] = b
            tried[id] = opts.now
            if #pick >= limit then break end
        end
    end
    return pick
end

return M
