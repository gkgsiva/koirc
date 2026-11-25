-- Wishlist: books you want that the Library does not have yet. Added on the device (also
-- offline) and sent to the Library at the next sync, where they join a typed list on the
-- Library's Auto download page ("From KOReader"), so the server searches for them and
-- downloads them. Once a book shows up in the catalog it is put on Read later, so that sync
-- (or the next) brings it to the device.
--
-- Server calls (gkgsiva/library): GET /api/autofill (the lists, can_edit), POST
-- /api/autofill/watches {kind="manual", name, text}, PATCH /api/autofill/watches/<id> {text},
-- POST /api/autofill/run {watch_id} (search now), GET /api/autofill/watches/<id>/items (what the
-- server found). Changing the lists needs an admin account. A server without them (404), an
-- account that may not (403) or no network: the wishes wait on the device, nothing is lost.
--
-- File cfg.wishlist_path: { items = { {id=, title=, author=, at=, state=, server=, detail=,
-- key=, arrived_at=} }, removed = { "Title by Author", ... }, watch_id=, note=, checked_at= }.
-- state: "waiting" (on this device only), "sent", "arrived". No KOReader dependencies.
local ltn12 = require("ltn12")
local util = require("librarysync/util")
local json = require("librarysync/json")

local M = {}

M.WATCH_NAME = "From KOReader"

--- "Title by Author", "Title - Author" or "Title | Author" -> title, author (author may be nil).
function M.parse(text)
    local line = util.trim(tostring(text or ""))
    if line == "" then return nil end
    local title, author = line:match("^(.-)%s+[bB][yY]%s+(.+)$")
    if not title then title, author = line:match("^(.-)%s+%-%s+(.+)$") end
    if not title then title, author = line:match("^(.-)%s*|%s*(.+)$") end
    title = util.trim(title or line)
    author = author and util.trim(author) or nil
    if author == "" then author = nil end
    if title == "" then return nil end
    return title, author
end

--- Lower case, letters and digits only, one space between words.
function M.norm(s)
    s = tostring(s or ""):lower():gsub("&", " and "):gsub("[%p%c]", " "):gsub("%s+", " ")
    s = util.trim(s):gsub("^the ", ""):gsub("^a ", ""):gsub("^an ", "")
    return s
end

function M.line(e)
    if e.author and e.author ~= "" then return e.title .. " by " .. e.author end
    return e.title
end

function M.load(cfg)
    local w = cfg.wishlist_path and util.load_table(cfg.wishlist_path) or {}
    w.items = w.items or {}
    w.removed = w.removed or {}
    return w
end

function M.save(cfg, w)
    if cfg.wishlist_path then util.save_table(cfg.wishlist_path, w) end
end

local function same(e, title, author)
    return M.norm(e.title) == M.norm(title) and M.norm(e.author or "") == M.norm(author or "")
end

--- Add a wish. Returns the entry, or nil, "duplicate" / "empty".
function M.add(cfg, title, author, now)
    title = util.trim(tostring(title or ""))
    if title == "" then return nil, "empty" end
    local w = M.load(cfg)
    for _, e in ipairs(w.items) do
        if same(e, title, author) and e.state ~= "arrived" then return nil, "duplicate" end
    end
    local e = { id = tostring(now or os.time()) .. "-" .. (#w.items + 1), title = title, author = author,
                at = now or os.time(), state = "waiting" }
    w.items[#w.items + 1] = e
    -- wished again after being taken off: it is not removed from the server any more
    for i = #w.removed, 1, -1 do
        local t, a = M.parse(w.removed[i])
        if t and same({ title = t, author = a }, title, author) then table.remove(w.removed, i) end
    end
    M.save(cfg, w)
    return e
end

--- Take a wish off. One the server already has is taken off its list at the next sync.
function M.remove(cfg, id)
    local w = M.load(cfg)
    for i, e in ipairs(w.items) do
        if e.id == id then
            table.remove(w.items, i)
            if e.state == "sent" then w.removed[#w.removed + 1] = M.line(e) end
            M.save(cfg, w)
            return true
        end
    end
    return false
end

function M.count(cfg, only_open)
    local n = 0
    for _, e in ipairs(M.load(cfg).items) do
        if not only_open or e.state ~= "arrived" then n = n + 1 end
    end
    return n
end

-- What the server's status for a list book means, in a few words.
M.SERVER_TEXT = {
    done = "downloaded on the Library", owned = "on the Library", due = "the Library searches for it soon",
    waiting = "not found yet, the Library tries again later", gave_up = "the Library could not find it",
    needs_author = "needs an author", unreleased = "not released yet", read = "skipped (marked Read)",
}

local function get_json(cfg, url)
    local out = {}
    local code, err = cfg.transport(url, cfg.headers, ltn12.sink.table(out))
    if not code then return nil, err end
    if code ~= 200 then return nil, code end
    local v = json.decode(table.concat(out))
    if type(v) ~= "table" then return nil, "not JSON" end
    return v
end

local function send(cfg, method, url, body)
    local httpmod = require("librarysync/http")
    local code, out = (cfg.send or httpmod.send)(method, url, cfg.headers, body)
    return code, out
end

-- The lines of a typed list, normalised, as a set.
local function line_set(text)
    local set = {}
    for raw in tostring(text or ""):gmatch("[^\n]+") do
        local t, a = M.parse(raw)
        if t then set[M.norm(t) .. "|" .. M.norm(a or "")] = true end
    end
    return set
end

local function key_of(title, author) return M.norm(title) .. "|" .. M.norm(author or "") end

--- Send the waiting wishes (and take removed ones off), then read back what the server found.
-- Returns { sent=, unsupported=true, refused=reason, error=, found= } (fields only when set).
function M.push(cfg, progress)
    local w = M.load(cfg)
    local res = {}
    local waiting, sent_any = {}, false
    for _, e in ipairs(w.items) do
        if e.state == "waiting" then waiting[#waiting + 1] = e end
        if e.state == "sent" then sent_any = true end
    end
    if #waiting == 0 and #w.removed == 0 and not sent_any then return res end
    if progress and progress("Sending the wishlist") == false then return res end
    local info, err = get_json(cfg, cfg.server .. "/api/autofill")
    if not info then
        if err == 404 then res.unsupported = true w.note = "unsupported"
        elseif err == 403 then res.refused = "account" w.note = "account"
        elseif type(err) == "number" then res.error = "HTTP " .. err
        else res.error = tostring(err) end
        M.save(cfg, w)
        return res
    end
    local watch
    for _, x in ipairs(type(info.watches) == "table" and info.watches or {}) do
        if type(x) == "table" and x.kind == "manual" and x.name == M.WATCH_NAME then watch = x break end
    end
    if (#waiting > 0 or #w.removed > 0) and info.can_edit == false then
        res.refused = "admin" w.note = "admin"
        M.save(cfg, w)
        return res
    end
    -- the list's text: what is there, plus the waiting wishes, minus the removed ones
    local text = watch and tostring(watch.text or "") or ""
    local have = line_set(text)
    local lines = {}
    local drop = {}
    for _, l in ipairs(w.removed) do
        local t, a = M.parse(l)
        if t then drop[key_of(t, a)] = true end
    end
    for raw in text:gmatch("[^\n]+") do
        local t, a = M.parse(raw)
        if not (t and drop[key_of(t, a)]) then lines[#lines + 1] = raw end
    end
    local added = 0
    for _, e in ipairs(waiting) do
        if not have[key_of(e.title, e.author)] then
            lines[#lines + 1] = M.line(e)
            added = added + 1
        end
    end
    local new_text = table.concat(lines, "\n")
    local changed = new_text ~= text
    local watch_id = watch and tonumber(watch.id)
    if changed then
        local code, body
        if watch_id then
            if #lines == 0 then
                code, body = send(cfg, "DELETE", cfg.server .. "/api/autofill/watches/" .. watch_id, "{}")
                if code == 200 then watch_id = nil end
            else
                code, body = send(cfg, "PATCH", cfg.server .. "/api/autofill/watches/" .. watch_id,
                    util.json_object({ text = new_text }))
            end
        elseif #lines > 0 then
            code, body = send(cfg, "POST", cfg.server .. "/api/autofill/watches",
                util.json_object({ kind = "manual", name = M.WATCH_NAME, text = new_text }))
            local v = (code == 200 or code == 201) and json.decode(body or "")
            watch_id = type(v) == "table" and tonumber(v.id) or nil
        end
        if code ~= 200 and code ~= 201 then
            if code == 404 then res.unsupported = true w.note = "unsupported"
            elseif code == 403 then res.refused = "admin" w.note = "admin"
            else res.error = code and ("HTTP " .. code) or tostring(body) end
            M.save(cfg, w)
            return res
        end
    end
    w.note = nil
    w.watch_id = watch_id
    w.removed = {}
    local now = os.time()
    for _, e in ipairs(waiting) do e.state, e.sent_at = "sent", now end
    res.sent = #waiting > 0 and #waiting or nil
    -- search right away (the server's schedule may be off, or a day away)
    if watch_id and added > 0 and cfg.wish_search_now ~= false then
        send(cfg, "POST", cfg.server .. "/api/autofill/run", util.json_object({ watch_id = watch_id }))
    end
    -- what the server found for each
    if watch_id then
        local items = get_json(cfg, cfg.server .. "/api/autofill/watches/" .. watch_id .. "/items")
        if type(items) == "table" and type(items.items) == "table" then
            local by = {}
            for _, it in ipairs(items.items) do
                if type(it) == "table" and it.title then by[key_of(it.title, it.author)] = it end
            end
            for _, e in ipairs(w.items) do
                local it = e.state == "sent" and by[key_of(e.title, e.author)]
                if it then
                    e.server = it.status
                    e.detail = type(it.last_detail) == "string" and it.last_detail ~= "" and it.last_detail or nil
                end
            end
        end
    end
    w.checked_at = now
    M.save(cfg, w)
    return res
end

-- Does catalog book b look like the wished-for book e?
local function matches(e, b)
    local wt, bt = M.norm(e.title), M.norm(b.title)
    if wt == "" or bt == "" then return false end
    if not (bt == wt or bt:find(wt, 1, true) == 1) then return false end
    if not e.author or e.author == "" then return bt == wt end
    local wa = M.norm(e.author)
    for _, a in ipairs(b.authors or {}) do
        local na = M.norm(a)
        if na == wa or na:find(wa, 1, true) or wa:find(na, 1, true) then return true end
        -- same last name is enough ("Le Guin" for "Ursula K. Le Guin")
        local last_w, last_a = wa:match("(%S+)$"), na:match("(%S+)$")
        if last_w and last_w == last_a and #last_w > 2 then return true end
    end
    return false
end
M._matches = matches

--- Wishes that are in the catalog now: they are marked arrived and returned as
-- { {entry=, book=, file=} } for the caller to put on Read later. Wishes never sent count too
-- (someone may have added the book on the server).
function M.arrivals(cfg, cat, pick_format)
    if not (cat and cat.books) then return {} end
    local w = M.load(cfg)
    local out = {}
    for _, e in ipairs(w.items) do
        if e.state ~= "arrived" then
            for _, b in ipairs(cat.books) do
                if matches(e, b) and b.files and #b.files > 0 then
                    local file = pick_format and pick_format(b.files) or b.files[1]
                    if type(file) == "table" and file[1] then file = file[1] end
                    e.state, e.key, e.arrived_at = "arrived", file.key, os.time()
                    out[#out + 1] = { entry = e, book = b, file = file }
                    break
                end
            end
        end
    end
    if #out > 0 then M.save(cfg, w) end
    return out
end

return M
