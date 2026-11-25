-- Reading-time estimates: how long a book still takes, from this reader's own speed (the
-- on-device reading stats: page turns and the time on each page) and the book's length.
-- Lengths: KOReader's page count for books opened on this device (saved in cfg.pages_path as
-- { [key] = {pages=, percent=, at=} }), else the Library's page count (library:pages, printed
-- pages) turned into screen pages with the ratio seen on books that have both.
-- No KOReader dependencies.
local util = require("librarysync/util")

local M = {}

M.DAYS = 30          -- speed from the last 30 days of reading
M.MIN_PAGES = 20     -- at least this many page turns…
M.MIN_SECS = 600     -- …and 10 minutes of reading before there is a speed to go by

--- Seconds per (screen) page from the stats ({ days = { ["YYYY-MM-DD"] = {pages=, secs=} } }).
-- Returns nil while there is too little to go by.
function M.secs_per_page(stats, now, days)
    now = now or os.time()
    local cut = os.date("%Y-%m-%d", now - (days or M.DAYS) * 86400)
    local pages, secs = 0, 0
    for day, d in pairs(stats and stats.days or {}) do
        if day >= cut and type(d) == "table" then
            pages = pages + (tonumber(d.pages) or 0)
            secs = secs + (tonumber(d.secs) or 0)
        end
    end
    if pages < M.MIN_PAGES or secs < M.MIN_SECS then return nil end
    return secs / pages
end

--- Screen pages per printed page, from books with both counts: the median, or nil.
-- pages: the pages file; printed: { [key] = Library page count }.
function M.ratio(pages, printed)
    local list = {}
    for key, p in pairs(pages or {}) do
        local lp = printed and tonumber(printed[key])
        local sp = type(p) == "table" and tonumber(p.pages)
        if lp and lp > 0 and sp and sp > 0 then
            local r = sp / lp
            if r >= 0.2 and r <= 6 then list[#list + 1] = r end
        end
    end
    if #list == 0 then return nil end
    table.sort(list)
    local mid = math.floor((#list + 1) / 2)
    if #list % 2 == 0 then return (list[mid] + list[mid + 1]) / 2 end
    return list[mid]
end

--- What is left of a book. opts: percent (0..1, how far it is read), screen_pages (KOReader's
-- count), printed (the Library's count), ratio, spp (seconds per screen page).
-- Returns secs (nil without a speed), screen pages left (nil without a length).
function M.left(opts)
    local percent = math.max(0, math.min(1, tonumber(opts.percent) or 0))
    local total = tonumber(opts.screen_pages)
    if not (total and total > 0) and tonumber(opts.printed) and tonumber(opts.printed) > 0 then
        total = tonumber(opts.printed) * (opts.ratio or 1)
    end
    if not (total and total > 0) then return nil, nil end
    local pages = math.max(0, math.floor(total * (1 - percent) + 0.5))
    if not opts.spp then return nil, pages end
    return pages * opts.spp, pages
end

--- "3h20", "45m", "<5m" (for lists).
function M.short(secs)
    if not secs then return nil end
    secs = math.floor(secs)
    if secs < 300 then return "<5m" end
    local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
    if h == 0 then return string.format("%dm", m) end
    if h >= 10 then return string.format("%dh", h + (m >= 30 and 1 or 0)) end
    return string.format("%dh%02d", h, m)
end

--- "about 3 h 20 min", "about 45 min", "a few minutes".
function M.long(secs)
    if not secs then return nil end
    secs = math.floor(secs)
    if secs < 300 then return "a few minutes" end
    local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
    if h == 0 then return string.format("about %d min", m) end
    return string.format("about %d h %02d min", h, m)
end

--- Remember a book's KOReader page count and place (called when it is closed or the device
-- sleeps). Kept small: only the books read on this device.
function M.note(path, key, pages, percent, now)
    if not (path and key and tonumber(pages) and tonumber(pages) > 0) then return end
    local all = util.load_table(path) or {}
    local old = all[key]
    percent = tonumber(percent)
    if old and old.pages == pages and old.percent == percent then return end
    all[key] = { pages = math.floor(pages), percent = percent, at = now or os.time() }
    util.save_table(path, all)
end

--- An estimator for many books at once (one load of each file): est(book, file) -> secs, pages.
-- cfg: pages_path, positions_path (or positions_file), status_path. stats: the reading stats.
-- cat: the catalog (for the ratio).
function M.estimator(cfg, stats, cat, now)
    local pages = cfg.pages_path and util.load_table(cfg.pages_path) or {}
    local pending = (cfg.positions_file or cfg.positions_path) and util.load_table(cfg.positions_file or cfg.positions_path) or {}
    local statuses = cfg.status_path and util.load_table(cfg.status_path) or {}
    local printed = {}
    for _, b in ipairs(cat and cat.books or {}) do
        if b.pages then for _, f in ipairs(b.files or {}) do printed[f.key] = b.pages end end
    end
    local spp = M.secs_per_page(stats, now)
    local ratio = M.ratio(pages, printed)
    local est = {
        spp = spp, ratio = ratio,
    }
    function est.left(book, file)
        local key = file and file.key
        local s = key and statuses[key]
        if s and s.status == "read" then return 0, 0, true end
        local p = key and pages[key]
        local percent = (key and type(pending[key]) == "table" and pending[key].percent)
            or (p and p.percent) or book.progress or 0
        if percent >= 0.995 then return 0, 0, true end
        local secs, left = M.left{ percent = percent, screen_pages = p and p.pages, printed = book.pages,
                                    ratio = ratio, spp = spp }
        return secs, left, false
    end
    return est
end

return M
