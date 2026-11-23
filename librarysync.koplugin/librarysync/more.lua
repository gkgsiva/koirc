-- v2.5: reading goals, battery and charger rules, bandwidth-friendly ordering, duplicates on
-- the device, the "new on this device" list, the server health check, reading stats and moving
-- books. No KOReader dependencies here (the specs run it with plain LuaJIT); the screens are
-- in main.lua and browser.lua.
local util = require("librarysync/util")
local M = {}

-------------------------------------------------------------------------------
-- Reading goals
-------------------------------------------------------------------------------

--- Books finished this year and this month, from the status store
-- ({ [key] = {status=, finished_at=} }, settings/librarysync_status.lua).
function M.finished_counts(statuses, now)
    now = now or os.time()
    local t = os.date("*t", now)
    local year, month = 0, 0
    for _, s in pairs(statuses or {}) do
        if type(s) == "table" and s.status == "read" then
            local at = tonumber(s.finished_at or s.at)
            if at then
                local f = os.date("*t", at)
                if f.year == t.year then
                    year = year + 1
                    if f.month == t.month then month = month + 1 end
                end
            end
        end
    end
    return year, month
end

local function days_in_year(y)
    return ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) and 366 or 365
end

--- How far along the goals are: { year = {done, goal, pace}, month = {done, goal, pace} }.
-- pace: how many books the goal expects by today (by the day of the year or month).
function M.goal_progress(goals, statuses, now)
    now = now or os.time()
    local t = os.date("*t", now)
    local year, month = M.finished_counts(statuses, now)
    local out = {}
    local yg, mg = tonumber(goals and goals.year) or 0, tonumber(goals and goals.month) or 0
    if yg > 0 then
        out.year = { done = year, goal = yg, pace = yg * t.yday / days_in_year(t.year) }
    end
    if mg > 0 then
        local dim = os.date("*t", os.time{ year = t.year, month = t.month + 1, day = 0, hour = 12 }).day
        out.month = { done = month, goal = mg, pace = mg * t.day / dim }
    end
    return out
end

-------------------------------------------------------------------------------
-- Battery and charger
-------------------------------------------------------------------------------

--- May an automatic sync run now? opts: { override, charger_only, min_battery (percent, 0 =
-- no limit) }; power: { capacity = percent, charging = bool }, or nil when the device cannot
-- tell (then it may). Returns true, or false and the reason in plain words.
function M.power_ok(opts, power)
    opts = opts or {}
    if opts.override or not power then return true end
    if power.charging then return true end
    if opts.charger_only then return false, "the device is not charging" end
    local min = tonumber(opts.min_battery) or 0
    local cap = tonumber(power.capacity)
    if min > 0 and cap and cap < min then
        return false, string.format("the battery is at %d%% (below %d%%)", cap, min)
    end
    return true
end

-------------------------------------------------------------------------------
-- Bandwidth-friendly ordering
-------------------------------------------------------------------------------

--- Order download items small first (books on Read later before everything), and leave out
-- books bigger than defer_over bytes (not on Read later; nil = none left out).
-- Returns the items to download and the ones left for later.
function M.order_items(items, small_first, defer_over)
    local keep, later = {}, {}
    for i, it in ipairs(items) do
        it._i = i
        if defer_over and it.size and it.size > defer_over and not it.queued then
            later[#later + 1] = it
        else
            keep[#keep + 1] = it
        end
    end
    if small_first then
        table.sort(keep, function(a, b)
            local qa, qb = a.queued and 0 or 1, b.queued and 0 or 1
            if qa ~= qb then return qa < qb end
            local sa, sb = a.size or math.huge, b.size or math.huge
            if sa ~= sb then return sa < sb end
            return a._i < b._i
        end)
    end
    for _, it in ipairs(items) do it._i = nil end
    return keep, later
end

--- Is this Wi-Fi network one of the trusted ones? ssid nil = cannot tell (not trusted).
function M.trusted(list, ssid)
    if not ssid or ssid == "" then return false end
    for _, s in ipairs(list or {}) do if s == ssid then return true end end
    return false
end

-------------------------------------------------------------------------------
-- Duplicates on the device
-------------------------------------------------------------------------------

M.BOOK_EXT = { epub = true, kepub = true, azw3 = true, azw = true, mobi = true, pdf = true, cbz = true,
               fb2 = true, txt = true, djvu = true, docx = true, rtf = true }

--- Every book file under dir (not in hidden folders or KOReader's .sdr folders).
-- lfs: libkoreader-lfs (or LuaFileSystem). Returns a sorted list of paths.
function M.walk(lfs, dir, out, depth)
    out = out or {}
    depth = depth or 0
    if depth > 8 then return out end
    local ok, iter, obj = pcall(lfs.dir, dir)
    if not ok then return out end
    local names = {}
    for name in iter, obj do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
            local p = dir .. "/" .. name
            local mode = lfs.attributes(p, "mode")
            if mode == "directory" then
                if not name:match("%.sdr$") then M.walk(lfs, p, out, depth + 1) end
            elseif mode == "file" then
                local ext = (name:match("%.([^.]+)$") or ""):lower()
                if M.BOOK_EXT[ext] and not name:match("%.part$") then out[#out + 1] = p end
            end
        end
    end
    return out
end

--- The book a file name stands for: no folder, format, "Series #n - " prefix, " (12)" suffix
-- the sync adds for clashing names, case or punctuation.
function M.title_key(path)
    local name = path:match("([^/]+)$") or path
    name = name:gsub("%.[^.]+$", "")
    name = name:gsub("^.-#%s*[%d.]+%s+%-%s+", "")
    name = name:gsub("%s*%(%d+%)$", "")
    name = name:lower():gsub("[%p%s]+", "")
    return name
end

--- Books on the device more than once (in two folders, or in two formats):
-- { {id=, paths={...}} }, biggest groups first. ignored: { [id] = true } groups you kept.
function M.duplicates(paths, ignored)
    local by, order = {}, {}
    for _, p in ipairs(paths) do
        local id = M.title_key(p)
        if id ~= "" then
            if not by[id] then by[id] = {} order[#order + 1] = id end
            table.insert(by[id], p)
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        if #by[id] > 1 and not (ignored or {})[id] then out[#out + 1] = { id = id, paths = by[id] } end
    end
    table.sort(out, function(a, b)
        if #a.paths ~= #b.paths then return #a.paths > #b.paths end
        return a.id < b.id
    end)
    return out
end

--- Which copy to keep by default: one with reading data (started), else the preferred
-- format, else the first. started(path) -> bool; pref: "epub", ...
function M.suggest_keep(paths, started, pref)
    for _, p in ipairs(paths) do if started and started(p) then return p end end
    if pref and pref ~= "all" then
        for _, p in ipairs(paths) do
            if (p:match("%.([^.]+)$") or ""):lower() == pref then return p end
        end
    end
    return paths[1]
end

-------------------------------------------------------------------------------
-- New on this device (what recent syncs brought in)
-------------------------------------------------------------------------------

M.RECENT_KEEP = 100

--- Add downloaded books to the list (cfg.recent_path): newest first, one entry per path.
-- entries: { {name=, path=, key=, folder=} }.
function M.add_recent(recent_path, entries, now)
    if not recent_path or #entries == 0 then return end
    now = now or os.time()
    local list = util.load_table(recent_path) or {}
    local seen = {}
    for _, e in ipairs(entries) do seen[e.path] = true end
    local out = {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        out[#out + 1] = { name = e.name, path = e.path, key = e.key, folder = e.folder, at = e.at or now }
    end
    for _, e in ipairs(list) do
        if not seen[e.path] then out[#out + 1] = e end
    end
    while #out > M.RECENT_KEEP do table.remove(out) end
    util.save_table(recent_path, out)
end

-------------------------------------------------------------------------------
-- Moving books (bulk "Move to a folder")
-------------------------------------------------------------------------------

--- Move a file into dir (rename, or copy and delete across file systems).
-- Returns the new path, or nil and the reason.
function M.move_file(src, dir)
    local name = src:match("([^/]+)$")
    local dst = dir:gsub("/+$", "") .. "/" .. name
    if dst == src then return dst end
    if util.file_size(dst) then return nil, "a file with that name is already there" end
    if not os.rename(src, dst) then
        if not util.copy_file(src, dst) then return nil, "cannot write to " .. dir end
        os.remove(src)
    end
    return dst
end

--- Record moved (or deliberately removed) copies in the sync state: the book's record follows
-- the file, and the old place is not filled again by later syncs. moves: { [old] = new|false }.
function M.note_moves(st, moves)
    st.files = st.files or {}
    st.skip_dests = st.skip_dests or {}
    st.moved = st.moved or {}
    for key, rec in pairs(st.files) do
        for old, new in pairs(moves) do
            if rec[old] then
                if new then rec[new] = util.file_size(new) or rec[old] st.moved[new] = true end
                rec[old] = nil
            end
        end
        if next(rec) == nil then st.files[key] = nil end
    end
    for old in pairs(moves) do st.skip_dests[old] = true st.moved[old] = nil end
end

--- Leave out of each item the places a book was moved away from or removed as a duplicate.
-- Items with no place left are dropped. Returns the number dropped.
function M.drop_skipped(items, skip)
    if not (skip and next(skip)) then return 0 end
    local n = 0
    for i = #items, 1, -1 do
        local it = items[i]
        local keep = {}
        for _, d in ipairs(it.dests or {}) do if not skip[d] then keep[#keep + 1] = d end end
        if #keep == 0 and #(it.dests or {}) > 0 and not it.queued then
            table.remove(items, i)
            n = n + 1
        elseif not it.queued then
            it.dests = keep
        end
    end
    return n
end

-------------------------------------------------------------------------------
-- Reading stats (kept on the device: the Library has no call to take them)
-------------------------------------------------------------------------------

M.IDLE = 300        -- seconds on one page counted at most (longer: put down, not read)
M.STATS_DAYS = 400  -- days kept

--- A page turn: one page read and the time spent on the page before (up to M.IDLE).
-- stats: { days = { ["YYYY-MM-DD"] = {pages=, secs=} } }; sess: { page=, at= } of this book.
-- Returns true when stats changed.
function M.stats_tick(stats, sess, page, now)
    now = now or os.time()
    stats.days = stats.days or {}
    local changed = false
    if sess.at and sess.page ~= nil and page ~= sess.page then
        local day = os.date("%Y-%m-%d", now)
        local d = stats.days[day] or { pages = 0, secs = 0 }
        d.pages = d.pages + 1
        local gap = now - sess.at
        if gap > 0 and gap <= M.IDLE then d.secs = d.secs + gap end
        stats.days[day] = d
        changed = true
    end
    sess.page, sess.at = page, now
    return changed
end

--- Drop days older than M.STATS_DAYS.
function M.stats_prune(stats, now)
    now = now or os.time()
    local cut = os.date("%Y-%m-%d", now - M.STATS_DAYS * 86400)
    for day in pairs(stats.days or {}) do
        if day < cut then stats.days[day] = nil end
    end
end

--- Add the pages and seconds of one stats table into another (the saved file and the
-- unsaved turns in memory).
function M.stats_merge(into, add)
    into.days = into.days or {}
    for day, d in pairs(add.days or {}) do
        local t = into.days[day] or { pages = 0, secs = 0 }
        t.pages, t.secs = t.pages + (d.pages or 0), t.secs + (d.secs or 0)
        into.days[day] = t
    end
    return into
end

local function day_key(t) return os.date("%Y-%m-%d", t) end

--- Monday 00:00 of the week holding t.
function M.week_start(t)
    local d = os.date("*t", t)
    local back = (d.wday + 5) % 7  -- days since Monday
    return os.time{ year = d.year, month = d.month, day = d.day - back, hour = 0 }
end

--- Totals: today, the last 7 days one by one, this week and the last weeks (Monday to Sunday).
-- Returns { today = {pages, secs}, days = { {day, pages, secs} } (newest first),
--           weeks = { {from, pages, secs} } (this week first) }.
function M.stats_summary(stats, now, ndays, nweeks)
    now = now or os.time()
    local days = (stats and stats.days) or {}
    local function get(day) local d = days[day] or {} return d.pages or 0, d.secs or 0 end
    local out = { days = {}, weeks = {} }
    local p, s = get(day_key(now))
    out.today = { pages = p, secs = s }
    local noon = os.time{ year = os.date("*t", now).year, month = os.date("*t", now).month,
                          day = os.date("*t", now).day, hour = 12 }
    for i = 0, (ndays or 7) - 1 do
        local t = noon - i * 86400
        local dp, ds = get(day_key(t))
        out.days[#out.days + 1] = { day = day_key(t), t = t, pages = dp, secs = ds }
    end
    local ws = M.week_start(now)
    for w = 0, (nweeks or 4) - 1 do
        local from = os.time{ year = os.date("*t", ws).year, month = os.date("*t", ws).month,
                              day = os.date("*t", ws).day - 7 * w, hour = 12 }
        local wp, wsec = 0, 0
        for i = 0, 6 do
            local dp, ds = get(day_key(from + i * 86400))
            wp, wsec = wp + dp, wsec + ds
        end
        out.weeks[#out.weeks + 1] = { from = day_key(from), pages = wp, secs = wsec }
    end
    return out
end

--- "1 h 05 min", "12 min", "0 min".
function M.duration(secs)
    secs = math.floor(tonumber(secs) or 0)
    local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%d h %02d min", h, m) end
    return string.format("%d min", m)
end

-------------------------------------------------------------------------------
-- Server health check ("Test connection")
-------------------------------------------------------------------------------

-- What the plugin uses on the server, how /api/v1 lists it, and what it is called.
M.FEATURES = {
    { route = "/api/v1/downloads/<int:download_id>/position", name = "Reading progress both ways" },
    { route = "/api/v1/downloads/<int:download_id>/status", name = "Reading status, Did not finish and ratings",
      since = "1.33" },
    { route = "/api/v1/downloads/<int:download_id>/highlights", name = "Highlights and notes" },
    { route = "/api/v1/downloads/<int:download_id>/next", name = "Next in series" },
}

local function get_body(cfg, url)
    local chunks = {}
    local ok, code, err = pcall(cfg.transport, url, cfg.headers, function(chunk)
        if chunk and #chunks < 4096 then chunks[#chunks + 1] = chunk end
        return 1
    end)
    if not ok then return nil, tostring(code) end
    if not code then return nil, tostring(err) end
    return code, table.concat(chunks)
end
M.get_body = get_body

--- Check the server step by step: reachable, login, the catalog, the account, the server
-- version and which of the plugin's features it supports.
-- Returns a list of { ok = true|false|nil (nil = just a note), text = "..." } in plain words,
-- and a short verdict.
function M.health(cfg)
    local lines = {}
    local function add(ok, text) lines[#lines + 1] = { ok = ok, text = text } end
    if not cfg.server then
        add(false, "No server address is set.")
        return lines, "not set up"
    end
    local code, body = get_body(cfg, cfg.server .. "/opds")
    if not code then
        add(false, "Cannot reach " .. cfg.server .. " (" .. tostring(body) .. "). Check the address and that Wi-Fi is on.")
        return lines, "unreachable"
    end
    add(true, "The server answers at " .. cfg.server .. ".")
    if code == 401 then
        add(false, cfg.auth == "bearer" and "The server refused the API token. Check it in the settings."
            or "The server refused the user name or password. Check them in the settings.")
        return lines, "sign-in refused"
    elseif code == 403 then
        add(false, "The server refused this account (it may be turned off).")
        return lines, "account refused"
    elseif code ~= 200 then
        add(false, string.format("The catalog did not open (HTTP %d). Is this the Library's address?", code))
        return lines, "no catalog"
    end
    local title = body:match("<title>(.-)</title>")
    if not body:find("<feed", 1, true) then
        add(false, "The address answers, but not with a book catalog. Is this the Library's address?")
        return lines, "no catalog"
    end
    add(true, "Signed in. The catalog “" .. require("librarysync/xml").unescape(title or "Library") .. "” opens.")
    local mcode, me = get_body(cfg, cfg.server .. "/api/me")
    local opds_only = false
    if mcode == 200 then
        local user = util.json_string(me, "username")
        opds_only = me:find('"opds_only"%s*:%s*true') ~= nil
        add(true, "Account: " .. (user or "?") .. (me:find('"is_admin"%s*:%s*true') and " (admin)" or "") .. ".")
    elseif mcode == 403 then
        opds_only = true
    end
    if opds_only then
        add(nil, "This account may only use the catalog: books and folders sync, and reading progress comes from the catalog, but places, statuses, ratings and notes cannot be sent.")
    end
    local vcode, v = get_body(cfg, cfg.server .. "/api/v1")
    if vcode == 200 then
        local version = util.json_string(v, "version")
        add(true, "Library server version " .. (version or "?") .. ".")
        local missing = {}
        for _, f in ipairs(M.FEATURES) do
            if v:find('"' .. f.route .. '"', 1, true) then
                add(true, f.name .. ": supported.")
            else
                missing[#missing + 1] = f.name
                add(false, f.name .. ": not on this server" .. (f.since and (" (needs Library " .. f.since .. " or newer)") or "") .. ".")
            end
        end
        local scode = get_body(cfg, cfg.server .. "/opds/search?q=a")
        if scode == 200 then add(true, "Search on the server: supported.")
        else add(false, "Search on the server: not on this server.") missing[#missing + 1] = "search" end
        add(nil, "Reading stats stay on this device: the Library has no place for them yet.")
        return lines, #missing == 0 and "all good" or (#missing .. " missing")
    elseif not opds_only then
        add(false, "The server does not say its version (no /api/v1): it is older than this plugin expects. Syncing books works; update the Library for progress, statuses and notes.")
        return lines, "old server"
    end
    return lines, "catalog only"
end

return M
