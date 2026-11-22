-- Reading status, ratings and notes, finished-book removal (with an undo list), next in
-- series, and cover/book-info refresh. Runs in the sync process (and its push-only variant
-- started when a book is closed); the reader and browser call the small helpers.
local ltn12 = require("ltn12")
local util = require("librarysync/util")
local httpmod = require("librarysync/http")

local M = {}

local function download_id(key) return tonumber((key or ""):match("^dl(%d+)$")) end
M.download_id = download_id

local function update_state(cfg, fn)
    if not cfg.state_path then return end
    local st = util.load_table(cfg.state_path) or {}
    st.files = st.files or {}
    fn(st)
    util.save_table(cfg.state_path, st)
end

-- Library (Hardcover) status names <-> ours <-> KOReader's book status.
M.FROM_SERVER = { ["Reading"] = "reading", ["Read"] = "read", ["Did not finish"] = "dnf", ["Paused"] = "paused" }
M.TO_KOREADER = { reading = "reading", read = "complete", dnf = "abandoned", paused = "abandoned" }
M.LABEL = { reading = "Currently reading", read = "Finished", dnf = "Did not finish", paused = "On hold" }

local function docsettings()
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and type(DocSettings) == "table" then return DocSettings end
end

local function mtime(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or type(lfs) ~= "table" or not lfs.attributes then return nil end
    local ok2, m = pcall(lfs.attributes, path, "modification")
    return ok2 and m or nil
end

-- KOReader stores the finished date as "YYYY-MM-DD".
local function day_time(s)
    local y, m, d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return util.iso_time(string.format("%s-%s-%sT12:00:00Z", y, m, d))
end

-- KOReader highlight colours -> the Library's four.
local COLOR = { yellow = "yellow", green = "green", olive = "green", blue = "blue", cyan = "blue",
                red = "pink", pink = "pink", purple = "pink", orange = "yellow", gray = "yellow" }

--- What the book's KOReader data says: our status name, or nil.
-- prev: our earlier record (an "On hold" book we marked as Did not finish stays DNF).
function M.koreader_status(summary, percent, prev)
    local s = summary and summary.status
    if s == "complete" then return "read" end
    if s == "abandoned" then return (prev and prev.status == "dnf") and "dnf" or "paused" end
    if s == "reading" then return "reading" end
    if (tonumber(percent) or 0) > 0 then return "reading" end
end

--- Highlights and notes of one book's KOReader data: { [id] = {text, note, color, cfi} }.
function M.annotations(ds)
    local out = {}
    local list = ds:readSetting("annotations")
    if type(list) ~= "table" then
        -- older KOReader: bookmarks carry the highlighted text and the note
        list = {}
        for _, b in ipairs(ds:readSetting("bookmarks") or {}) do
            if b.highlighted or (b.text and b.text ~= "" and b.pos0) then
                list[#list + 1] = { datetime = b.datetime, text = b.notes, note = b.text ~= b.notes and b.text or nil,
                                    pos0 = b.pos0, pos1 = b.pos1, page = b.page, color = b.color }
            end
        end
    end
    for _, a in ipairs(list) do
        local text = a.text and tostring(a.text) or ""
        if text ~= "" and (a.pos0 or a.page) then
            local where = a.pos0 and (tostring(a.pos0) .. (a.pos1 and ("|" .. tostring(a.pos1)) or "")) or ("page:" .. tostring(a.page))
            local id = tostring(a.datetime or where)
            out[id] = { text = text, note = a.note and tostring(a.note) or "", color = COLOR[a.color or "yellow"] or "yellow",
                        cfi = "koreader:" .. where, chapter = a.chapter }
        end
    end
    return out
end

--- Read the KOReader data of the downloaded books: status (Currently reading, Finished, On
-- hold / Did not finish), rating and review, and highlights with notes. Only books whose data
-- file changed since the last look are read (only: a set of paths to read, the book just closed).
-- Changes go to cfg.status_path and cfg.notes_path for the push; a newly finished book is also
-- queued as 100% for the position push. Returns the number of books whose data was read.
function M.collect(cfg, state, only)
    local DocSettings = docsettings()
    if not (DocSettings and cfg.status_path) then return 0 end
    local statuses = util.load_table(cfg.status_path) or {}
    local notes = cfg.notes_path and util.load_table(cfg.notes_path) or {}
    local pending = cfg.positions_path and (util.load_table(cfg.positions_path) or {}) or nil
    local scanned, finished = {}, {}
    local seen = state.scan_mtime or {}
    local n, changed_pos = 0, false
    local now = os.time()
    for key, rec in pairs(state.files or {}) do
        if download_id(key) then
            for path in pairs(rec) do
                if not only or only[path] then
                    local sidecar = DocSettings.findSidecarFile and DocSettings:findSidecarFile(path)
                        or (DocSettings:hasSidecarFile(path) and true)
                    local m = type(sidecar) == "string" and mtime(sidecar) or nil
                    if sidecar and (only or not m or seen[path] ~= m) then
                        local ok, ds = pcall(DocSettings.open, DocSettings, path)
                        if ok and ds then
                            n = n + 1
                            local summary = ds:readSetting("summary") or {}
                            local s = statuses[key] or {}
                            local st = M.koreader_status(summary, ds:readSetting("percent_finished"), s)
                            if st and st ~= s.status then
                                s.status, s.at = st, now
                                if st == "read" then
                                    s.finished_at = day_time(summary.modified) or now
                                    if s.finished_at > now then s.finished_at = now end
                                end
                            end
                            if st == "read" and pending and not (state.finished or {})[key] then
                                if not (pending[key] and pending[key].percent == 1) then
                                    pending[key] = { percent = 1, at = now, tz = 0 }
                                    changed_pos = true
                                end
                                finished[key] = true
                            end
                            local rating = tonumber(summary.rating)
                            if rating and rating > 0 then s.rating = rating end
                            local review = summary.note and tostring(summary.note) or nil
                            if review == "" then review = nil end
                            s.review = review
                            if next(s) then statuses[key] = s end
                            if cfg.notes_path and cfg.send_notes ~= false then
                                local book = notes[key] or { items = {} }
                                for id, h in pairs(M.annotations(ds)) do
                                    local old = book.items[id]
                                    if old then
                                        old.text, old.note, old.color = h.text, h.note, h.color
                                    else
                                        book.items[id] = h
                                    end
                                end
                                if next(book.items) then notes[key] = book end
                            end
                            if m then scanned[path] = m end
                        end
                        break  -- one copy of a book is enough
                    end
                end
            end
        end
    end
    util.save_table(cfg.status_path, statuses)
    if cfg.notes_path then util.save_table(cfg.notes_path, notes) end
    if changed_pos then util.save_table(cfg.positions_path, pending) end
    update_state(cfg, function(st)
        st.scan_mtime = st.scan_mtime or {}
        for p, mm in pairs(scanned) do st.scan_mtime[p] = mm end
        st.finished = st.finished or {}
        for k in pairs(finished) do st.finished[k] = true end
    end)
    state.scan_mtime = state.scan_mtime or {}
    for p, mm in pairs(scanned) do state.scan_mtime[p] = mm end
    return n
end

local function send(cfg, method, url, body)
    return (cfg.send or httpmod.send)(method, url, cfg.headers, body)
end

-- Ours -> the Library's status call (PUT /api/downloads/<id>/status). The Library has no
-- On hold, so "paused" stays on this device.
M.TO_SERVER = { reading = "reading", read = "finished", dnf = "dnf" }
-- The Library's reading_status element -> ours (want_to_read has no KOReader status).
M.FROM_SERVER_STATUS = { reading = "reading", finished = "read", dnf = "dnf" }

--- A rating the Library takes: 0.5 to 5 in half steps.
function M.half_rating(r)
    r = tonumber(r)
    if not r or r <= 0 then return nil end
    return math.max(0.5, math.min(5, math.floor(r * 2 + 0.5) / 2))
end

local function iso(t)
    return t and os.date("!%Y-%m-%dT%H:%M:%SZ", t) or nil
end

--- Send statuses and ratings that changed (PUT /api/downloads/<id>/status with only the
-- changed fields: status, rating, finished_at). The Library answers 404 both for a book it no
-- longer has and, on an older server, for the missing call: a GET of the book's position tells
-- them apart. On an older server Finished and Currently reading count as sent (the position
-- push already says so), and Did not finish and ratings stay queued until the server has it.
-- Returns sent, unsupported.
function M.push_status(cfg, progress)
    local statuses = cfg.status_path and util.load_table(cfg.status_path)
    if not statuses then return 0 end
    local sent, unsupported = 0, false
    local done = {}
    for key, s in pairs(statuses) do
        local id = download_id(key)
        local status_changed = s.status and s.status ~= s.sent_status
        local rating_changed = s.rating and s.rating ~= s.sent_rating
        local server_status = status_changed and M.TO_SERVER[s.status] or nil
        local server_rating = rating_changed and M.half_rating(s.rating) or nil
        if id and (status_changed or rating_changed) and not server_status and not server_rating then
            -- nothing the Library can take (On hold): kept on this device only
            done[key] = { status = s.status, rating = s.rating }
        elseif id and (server_status or server_rating) and not unsupported then
            if progress and progress("Sending reading status") == false then break end
            local body = {}
            if server_status then body.status = server_status end
            if server_rating then body.rating = server_rating end
            if server_status == "finished" and s.finished_at then body.finished_at = iso(s.finished_at) end
            local url = cfg.server .. "/api/downloads/" .. id
            local code, resp = send(cfg, "PUT", url .. "/status", util.json_object(body))
            if code == 200 or code == 201 or code == 204 then
                done[key] = { status = s.status, rating = s.rating }
                sent = sent + 1
            elseif code == 404 or code == 405 or code == 501 then
                local pcode = code == 404 and send(cfg, "GET", url .. "/position", "") or nil
                if pcode == 404 or (code == 404 and tostring(resp or ""):find('"error"', 1, true)) then
                    done[key] = { status = s.status, rating = s.rating }  -- the book is gone from the server
                else
                    unsupported = true
                end
            elseif code == 400 then
                done[key] = { status = s.status, rating = s.rating }  -- refused: sending it again will not help
            elseif code == 401 or code == 403 or not code then
                break
            end
        end
        if unsupported and status_changed and (s.status == "read" or s.status == "reading") then
            done[key] = done[key] or { status = s.status, rating = s.sent_rating, partial = true }
        end
    end
    -- re-read: the reader may have changed one meanwhile
    local now = util.load_table(cfg.status_path) or {}
    for key, d in pairs(done) do
        local s = now[key]
        if s then
            if s.status == d.status then s.sent_status = d.status end
            if not d.partial and s.rating == d.rating then s.sent_rating = d.rating end
        end
    end
    util.save_table(cfg.status_path, now)
    return sent, unsupported
end

M.NOTES_MAX = 200

--- Send new highlights and notes (POST /api/downloads/<id>/highlights) and changed notes
-- (PATCH /api/highlights/<id>). Highlights deleted on the device are left on the server.
-- Returns the number sent.
function M.push_notes(cfg, progress)
    local notes = cfg.notes_path and util.load_table(cfg.notes_path)
    if not notes then return 0 end
    local n, stop = 0, false
    for key, book in pairs(notes) do
        local id = download_id(key)
        for _, h in pairs(id and book.items or {}) do
            if stop or n >= M.NOTES_MAX then break end
            if not h.dropped and (not h.sent_id or (h.note or "") ~= (h.sent_note or "")) then
                if progress and progress("Sending highlights and notes") == false then stop = true break end
                local code, resp
                if not h.sent_id then
                    code, resp = send(cfg, "POST", cfg.server .. "/api/downloads/" .. id .. "/highlights",
                        util.json_object({ cfi = h.cfi, text = h.text, note = h.note or "", color = h.color or "yellow" }))
                    if code == 201 or code == 200 then
                        h.sent_id = util.json_number(resp, "id") or true
                        h.sent_note = h.note or ""
                        n = n + 1
                    elseif code == 404 then
                        h.dropped = true  -- the book is gone from the server
                    elseif code == 401 or code == 403 or not code then
                        stop = true
                    end
                elseif type(h.sent_id) == "number" then
                    code = send(cfg, "PATCH", cfg.server .. "/api/highlights/" .. h.sent_id,
                        util.json_object({ note = h.note or "" }))
                    if code == 200 then h.sent_note = h.note or "" n = n + 1
                    elseif code == 404 then h.dropped = true  -- deleted on the server: not brought back
                    elseif code == 401 or code == 403 or not code then stop = true end
                else
                    h.sent_note = h.note or ""
                end
            end
        end
    end
    -- merge into what is on disk now (the reader may have collected more meanwhile)
    local now = util.load_table(cfg.notes_path) or {}
    for key, book in pairs(notes) do
        local cur = now[key]
        if cur then
            for hid, h in pairs(book.items) do
                local c = cur.items[hid]
                if c then c.sent_id, c.sent_note, c.dropped = h.sent_id, h.sent_note, h.dropped end
            end
        end
    end
    util.save_table(cfg.notes_path, now)
    return n
end

--- A catalog book's status on the Library, as ours: this account's own status when the server
-- sends it (library:reading_status), else the Hardcover shelf (library:status).
function M.server_status(b)
    if b.reading_status then return M.FROM_SERVER_STATUS[b.reading_status] end
    return b.status and M.FROM_SERVER[b.status] or nil
end

--- Statuses and ratings set on the Library (any device, the web app, or Hardcover) since the
-- last sync, for the books on this device: saved in cfg.remote_status_path as
-- { [key] = {status=, rating=} }; the plugin applies them to KOReader's book data after the
-- sync. A status or rating changed here and not sent yet wins.
-- Returns the number of books with something new.
function M.pull_status(cfg, cat, state)
    if not (cfg.remote_status_path and cat and cat.books) then return 0 end
    local statuses = cfg.status_path and util.load_table(cfg.status_path) or {}
    local remote = util.load_table(cfg.remote_status_path) or {}
    local seen, rseen = state.status_seen or {}, state.rating_seen or {}
    local newseen, newrseen, n = {}, {}, 0
    for _, b in ipairs(cat.books) do
        local server = M.server_status(b)
        local rating = tonumber(b.my_rating)
        for _, f in ipairs(b.files or {}) do
            if (state.files or {})[f.key] then
                local s = statuses[f.key]
                local r = remote[f.key]
                if type(r) ~= "table" then r = r and { status = r } or {} end
                local changed = false
                if server and seen[f.key] ~= server then
                    newseen[f.key] = server
                    local unsent = s and s.status and s.status ~= s.sent_status
                    if not unsent and (not s or s.status ~= server) then r.status, changed = server, true end
                end
                if rating and rseen[f.key] ~= rating then
                    newrseen[f.key] = rating
                    local unsent = s and s.rating and s.rating ~= s.sent_rating
                    if not unsent and (not s or M.half_rating(s.rating) ~= rating) then r.rating, changed = rating, true end
                end
                if changed then
                    remote[f.key] = r
                    n = n + 1
                end
            end
        end
    end
    if next(newseen) or next(newrseen) then
        util.save_table(cfg.remote_status_path, remote)
        update_state(cfg, function(st)
            st.status_seen = st.status_seen or {}
            st.rating_seen = st.rating_seen or {}
            for k, v in pairs(newseen) do st.status_seen[k] = v end
            for k, v in pairs(newrseen) do st.rating_seen[k] = v end
        end)
        state.status_seen = state.status_seen or {}
        state.rating_seen = state.rating_seen or {}
        for k, v in pairs(newseen) do state.status_seen[k] = v end
        for k, v in pairs(newrseen) do state.rating_seen[k] = v end
    end
    return n
end

--- Record a status (and rating) set on this device: it goes out with the next push.
function M.set_local(cfg, key, fields)
    if not (cfg.status_path and key) then return end
    local statuses = util.load_table(cfg.status_path) or {}
    local s = statuses[key] or {}
    for k, v in pairs(fields) do s[k] = v end
    s.at = os.time()
    if fields.status == "read" and not fields.finished_at then s.finished_at = s.finished_at or os.time() end
    statuses[key] = s
    util.save_table(cfg.status_path, statuses)
end

-------------------------------------------------------------------------------
-- Finished books: auto-remove after N days, storage budget, undo list
-------------------------------------------------------------------------------

--- Bytes the plugin's downloads take, from the sizes the sync recorded.
function M.used_bytes(state)
    local used = 0
    for _, rec in pairs(state.files or {}) do
        for _, size in pairs(rec) do used = used + (tonumber(size) or 0) end
    end
    return used
end

--- Downloaded books that are finished: { {key, paths, size, finished_at, file, title} }, oldest
-- finished first. Finished = Finished on this device, or read to the end on the Library while
-- not re-started here. Books on Read later, brought back from the undo list, or open are left out.
function M.finished_books(cfg, cat, state)
    local statuses = cfg.status_path and util.load_table(cfg.status_path) or {}
    local queue = cfg.queue_path and util.load_table(cfg.queue_path) or {}
    local restored = state.restored or {}
    local by_key = {}
    for _, b in ipairs(cat and cat.books or {}) do
        for _, f in ipairs(b.files or {}) do by_key[f.key] = { book = b, file = f } end
    end
    local out = {}
    for key, rec in pairs(state.files or {}) do
        if download_id(key) and not queue[key] and not restored[key] then
            local s = statuses[key]
            local c = by_key[key]
            local at
            if s and s.status then
                if s.status == "read" then at = s.finished_at or s.at end
            elseif c and (c.book.progress or 0) >= 0.98 then
                at = c.book.last_read
            end
            if at then
                local paths, size, open = {}, 0, false
                for p, sz in pairs(rec) do
                    if cfg.open_path and p == cfg.open_path then open = true end
                    paths[#paths + 1] = p
                    size = size + (tonumber(sz) or 0)
                end
                table.sort(paths)
                if not open and #paths > 0 then
                    out[#out + 1] = { key = key, paths = paths, size = size, finished_at = at,
                                      file = c and c.file, title = c and c.book.title or paths[1]:match("([^/]+)$") }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.finished_at ~= b.finished_at then return a.finished_at < b.finished_at end
        return a.key < b.key
    end)
    return out
end

M.UNDO_KEEP = 100

--- Delete these finished books from the device (the book files only: KOReader's reading
-- data, highlights and notes stay, so a book brought back continues where it was). They are
-- not downloaded again by later syncs, and each goes on the undo list (cfg.removed_path).
-- why: "days" or "budget". Returns the list of titles removed and the bytes freed.
function M.remove_books(cfg, books, why, state)
    if #books == 0 then return {}, 0 end
    local undo = cfg.removed_path and util.load_table(cfg.removed_path) or {}
    local names, freed, gone = {}, 0, {}
    local now = os.time()
    for _, b in ipairs(books) do
        local removed = false
        for _, p in ipairs(b.paths) do
            if os.remove(p) or not util.file_size(p) then removed = true end
        end
        if removed then
            gone[b.key] = true
            freed = freed + (b.size or 0)
            names[#names + 1] = b.title
            table.insert(undo, 1, { key = b.key, paths = b.paths, title = b.title, size = b.size, why = why,
                                    at = now, finished_at = b.finished_at, file = b.file })
        end
    end
    while #undo > M.UNDO_KEEP do table.remove(undo) end
    if cfg.removed_path then util.save_table(cfg.removed_path, undo) end
    update_state(cfg, function(st)
        st.removed = st.removed or {}
        for k in pairs(gone) do st.files[k] = nil st.removed[k] = now end
    end)
    if state then
        state.removed = state.removed or {}
        for k in pairs(gone) do (state.files or {})[k] = nil state.removed[k] = now end
    end
    return names, freed
end

--- "Remove finished books after N days": the books finished at least cfg.remove_after_days ago.
function M.auto_remove(cfg, cat, state, now)
    local days = tonumber(cfg.remove_after_days)
    if not days or days <= 0 then return {}, 0 end
    now = now or os.time()
    local due = {}
    for _, b in ipairs(M.finished_books(cfg, cat, state)) do
        if b.finished_at <= now - days * 86400 then due[#due + 1] = b end
    end
    return M.remove_books(cfg, due, "days", state)
end

--- Storage budget: remove the oldest finished books until `need` more bytes fit under
-- cfg.budget. Returns true when they fit, and the titles removed.
function M.make_room(cfg, cat, state, need, key)
    local budget = tonumber(cfg.budget)
    if not budget or budget <= 0 then return true, {} end
    -- the book about to be downloaded: its earlier copy (if any) is replaced, not added
    local own = 0
    for _, sz in pairs(key and (state.files or {})[key] or {}) do own = own + (tonumber(sz) or 0) end
    if not need or need == 0 then need = own end
    local used = M.used_bytes(state) - own
    if used + need <= budget then return true, {} end
    local pick, freed = {}, 0
    for _, b in ipairs(M.finished_books(cfg, cat, state)) do
        if used - freed + need <= budget then break end
        if b.key ~= key then
            pick[#pick + 1] = b
            freed = freed + b.size
        end
    end
    local names = M.remove_books(cfg, pick, "budget", state)
    return M.used_bytes(state) - own + need <= budget, names
end

--- Undo: bring a removed book back. It is queued for the next sync (or downloaded right
-- away by the caller), into the place it had, and is not removed again by itself.
function M.restore(cfg, entry)
    update_state(cfg, function(st)
        st.removed = st.removed or {}
        st.removed[entry.key] = nil
        st.restored = st.restored or {}
        st.restored[entry.key] = os.time()
    end)
    M.forget_removed(cfg, entry)
    if entry.file and cfg.queue_path then
        local q = util.load_table(cfg.queue_path) or {}
        q[entry.key] = { file = entry.file, title = entry.title, at = os.time(), path = entry.paths and entry.paths[1] }
        util.save_table(cfg.queue_path, q)
        return true
    end
    return false
end

function M.forget_removed(cfg, entry)
    local undo = cfg.removed_path and util.load_table(cfg.removed_path) or {}
    for i = #undo, 1, -1 do
        if undo[i].key == entry.key and undo[i].at == entry.at then table.remove(undo, i) end
    end
    if cfg.removed_path then util.save_table(cfg.removed_path, undo) end
end

-------------------------------------------------------------------------------
-- Next in series
-------------------------------------------------------------------------------

local function lower(s) return tostring(s or ""):lower() end

--- The catalog book a file key belongs to.
function M.book_of(cat, key)
    for _, b in ipairs(cat and cat.books or {}) do
        for _, f in ipairs(b.files or {}) do if f.key == key then return b, f end end
    end
end

--- The next book of the same series in the catalog (the lowest number above this one).
function M.next_in_catalog(cat, book)
    local cur = book and tonumber(book.number or "")
    if not (cur and book.series and book.series ~= "") then return nil end
    local best, bn
    for _, b in ipairs(cat and cat.books or {}) do
        local n = tonumber(b.number or "")
        if b ~= book and n and n > cur and lower(b.series) == lower(book.series) and (not bn or n < bn) then
            best, bn = b, n
        end
    end
    return best
end

--- Books whose next one was not in the catalog: ask the Library at each sync (GET
-- /api/downloads/<id>/next). When the Library has it, it goes on Read later; when it does not,
-- the Library is asked to find it once (POST .../next/queue), and the next syncs look again,
-- for 30 days. Returns the titles put on Read later.
function M.next_requests(cfg, cat, state, progress)
    local wanted = state.next_wanted

    if not (wanted and next(wanted)) then return {} end
    local queued, drop, asked = {}, {}, {}
    local now = os.time()
    for key, w in pairs(wanted) do
        local id = download_id(key)
        if not id or now - (w.at or now) > 30 * 86400 then
            drop[key] = true
        else
            if progress and progress("Looking for the next books in series") == false then break end
            local out = {}
            local code = cfg.transport(cfg.server .. "/api/downloads/" .. id .. "/next", cfg.headers, ltn12.sink.table(out))
            local body = table.concat(out)
            if code == 200 then
                if body:find('"next"%s*:%s*null') then
                    drop[key] = true  -- the last one, or not in a series the Library tracks
                else
                    local did = util.json_number(body, "download_id")
                    local _b, f = M.book_of(cat, did and ("dl" .. did))
                    if f then
                        if cfg.queue_path then
                            local q = util.load_table(cfg.queue_path) or {}
                            if not q[f.key] and not (state.files or {})[f.key] then
                                q[f.key] = { file = f, dir = (f.folders or {})[1], title = util.json_string(body, "title") or f.name, at = now }
                                util.save_table(cfg.queue_path, q)
                                queued[#queued + 1] = q[f.key].title
                            end
                        end
                        drop[key] = true
                    elseif body:find('"unreleased"%s*:%s*true') then
                        -- not out yet: keep looking (until the 30 days are over)
                    elseif not w.asked and not body:find('"owned"%s*:%s*true') then
                        local c = send(cfg, "POST", cfg.server .. "/api/downloads/" .. id .. "/next/queue", "{}")
                        if c == 200 or c == 409 then asked[key] = true end
                        if c == 404 then drop[key] = true end
                    end
                end
            elseif code == 404 then
                drop[key] = true
            elseif code == 401 or code == 403 then
                break
            end
        end
    end
    update_state(cfg, function(st)
        st.next_wanted = st.next_wanted or {}
        for k in pairs(drop) do st.next_wanted[k] = nil end
        for k in pairs(asked) do if st.next_wanted[k] then st.next_wanted[k].asked = true end end
    end)
    return queued
end

-------------------------------------------------------------------------------
-- Covers and book info
-------------------------------------------------------------------------------

M.META_MAX = 100

local function strip_series(summary)
    summary = tostring(summary or "")
    return (summary:gsub("^Series: [^\n]*\n?\n?", ""))
end

local function signature(b, summary)
    return table.concat({ b.title or "", table.concat(b.authors or {}, ","), b.series or "", b.number or "",
                          b.cover or "", tostring(#(summary or "")) }, "|")
end

--- Write the Library's title, authors, series and description as KOReader custom book info,
-- and its cover as the custom cover, for the books on the device whose info changed since the
-- last time (the book files are not touched or downloaded again). At most META_MAX books per
-- sync. Returns the paths changed (the plugin tells the cover browser to look again).
function M.refresh_meta(cfg, cat, state, progress, force)
    local DocSettings = docsettings()
    if not (DocSettings and DocSettings.openSettingsFile and cat and cat.books) then return {} end
    local summaries = cfg.summaries_path and util.load_table(cfg.summaries_path) or {}
    local sigs = state.meta_sig or {}
    local changed, newsig, count = {}, {}, 0
    for _, b in ipairs(cat.books) do
        if count >= M.META_MAX then break end
        local summary = summaries[b.id]
        local sig = signature(b, summary)
        for _, f in ipairs(b.files or {}) do
            local rec = (state.files or {})[f.key]
            if rec and (force or sigs[f.key] ~= sig) then
                if progress and progress("Updating covers and book info") == false then return changed end
                count = count + 1
                local old = sigs[f.key] or ""
                local cover_changed = force or old:match("^[^|]*|[^|]*|[^|]*|[^|]*|([^|]*)") ~= (b.cover or "")
                local cover_tmp
                if b.cover and b.cover ~= "" and cover_changed and cfg.base then
                    local ext = (b.cover:gsub("[?#].*$", ""):match("%.(%a+)$") or "jpg"):lower()
                    if ext ~= "png" and ext ~= "jpeg" and ext ~= "webp" and ext ~= "gif" then ext = "jpg" end
                    cover_tmp = cfg.base .. "/.librarysync-cover." .. ext
                    local fh = io.open(cover_tmp, "wb")
                    local ok_code
                    if fh then
                        local same = util.origin(b.cover) == util.origin(cfg.server)
                        local code = cfg.transport(b.cover, same and cfg.headers or { ["User-Agent"] = "KOReader-LibrarySync" },
                            ltn12.sink.file(fh))
                        ok_code = code == 200
                    end
                    if not ok_code or (util.file_size(cover_tmp) or 0) == 0 then
                        os.remove(cover_tmp)
                        cover_tmp = nil
                    end
                end
                local props = {
                    title = b.title, authors = (#(b.authors or {}) > 0) and table.concat(b.authors, "\n") or nil,
                    series = (b.series and b.series ~= "") and b.series or nil,
                    series_index = tonumber(b.number or ""),
                    description = (summary and strip_series(summary) ~= "") and strip_series(summary) or nil,
                }
                for path in pairs(rec) do
                    if util.file_size(path) then
                        local existing = DocSettings.findCustomMetadataFile and DocSettings:findCustomMetadataFile(path)
                        local custom = DocSettings.openSettingsFile(existing or nil)
                        if not custom:readSetting("doc_props") then
                            local orig
                            local sidecar = DocSettings.findSidecarFile and DocSettings:findSidecarFile(path)
                            if sidecar then
                                local okd, data = pcall(dofile, sidecar)
                                orig = okd and type(data) == "table" and data.doc_props or nil
                            end
                            custom:saveSetting("doc_props", orig or { title = path:match("([^/]+)%.[^.]+$") })
                        end
                        custom:saveSetting("custom_props", props)
                        pcall(custom.flushCustomMetadata, custom, path)
                        if cover_tmp and DocSettings.flushCustomCover then
                            pcall(DocSettings.flushCustomCover, DocSettings, path, cover_tmp)
                        end
                        changed[#changed + 1] = path
                    end
                end
                if cover_tmp then os.remove(cover_tmp) end
                newsig[f.key] = sig
            end
        end
    end
    if next(newsig) then
        update_state(cfg, function(st)
            st.meta_sig = st.meta_sig or {}
            for k, v in pairs(newsig) do st.meta_sig[k] = v end
        end)
        state.meta_sig = state.meta_sig or {}
        for k, v in pairs(newsig) do state.meta_sig[k] = v end
    end
    return changed
end

return M
