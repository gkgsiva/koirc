--[[--
Followed authors: authors followed on Hardcover plus ones followed from the
plugin (a result, a book, the open book). After a sync, new books by them are
listed under "New releases"; for authors with auto-download on, books that
are out are downloaded in the background.

settings.followed_authors: array of { name, id (Hardcover author id, once
known), auto = true (download new books), hardcover = true (followed on
Hardcover; kept here only to remember auto) }.

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local Hardcover = require("koirc/hardcover")

local M = {}

-- Books by followed authors queued per sync at most.
M.PER_SYNC = 3

local function key(name) return Hardcover.normalize(name) end

function M.list(s)
    if type(s.followed_authors) ~= "table" then s.followed_authors = {} end
    return s.followed_authors
end

--- The entry for an author (by name, ignoring case and accents), or nil.
function M.find(s, name)
    local k = key(name)
    if k == "" then return nil end
    for i, a in ipairs(M.list(s)) do
        if key(a.name) == k then return a, i end
    end
end

--- Follow an author. Returns the entry and true when it is new.
function M.add(s, name, id)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    local a = M.find(s, name)
    if a then
        if id and not a.id then a.id = id end
        a.hardcover = nil -- now followed here too
        a.mine = true
        return a, false
    end
    a = { name = name, id = id, mine = true }
    local list = M.list(s)
    list[#list + 1] = a
    table.sort(list, function(x, y) return key(x.name) < key(y.name) end)
    return a, true
end

--- Stop following (in the plugin; a follow on Hardcover stays there).
function M.remove(s, name)
    local _a, i = M.find(s, name)
    if i then table.remove(M.list(s), i) return true end
    return false
end

function M.setAuto(s, name, on)
    local a = M.find(s, name)
    if not a then
        a = M.add(s, name)
        if not a then return end
        a.mine = nil
        a.hardcover = true
    end
    a.auto = on and true or nil
    return a
end

--- Authors to look up new books for: those followed on Hardcover (array
-- of {id, name}) plus the plugin's own with a known id, without doubles.
function M.merge(hc_authors, s)
    local out, seen_id, seen_name = {}, {}, {}
    for _i, a in ipairs(hc_authors or {}) do
        if a.id and not seen_id[a.id] then
            seen_id[a.id] = true
            if a.name then seen_name[key(a.name)] = true end
            out[#out + 1] = { id = a.id, name = a.name, hardcover = true }
        end
    end
    for _i, a in ipairs(M.list(s)) do
        if a.mine and a.id and not seen_id[a.id] and not seen_name[key(a.name)] then
            seen_id[a.id] = true
            out[#out + 1] = { id = a.id, name = a.name }
        end
    end
    return out
end

--- Own follows that still need their Hardcover id looked up.
function M.unresolved(s)
    local out = {}
    for _i, a in ipairs(M.list(s)) do
        if a.mine and not a.id and not a.not_found then out[#out + 1] = a end
    end
    return out
end

--- Pick the Hardcover author that is this name from search hits
-- ({id, name}), or nil.
function M.bestAuthor(name, hits)
    local k = key(name)
    for _i, h in ipairs(hits or {}) do
        if key(h.name) == k then return h end
    end
    -- "Sanderson, Brandon" or a middle initial: same words in any order.
    local want = {}
    for w in k:gmatch("%S+") do if #w > 1 then want[w] = true end end
    for _i, h in ipairs(hits or {}) do
        local all, n = true, 0
        for w in key(h.name):gmatch("%S+") do
            if #w > 1 then
                n = n + 1
                if not want[w] then all = false end
            end
        end
        if all and n > 0 then return h end
    end
end

--- Is the book out already? release_date "YYYY-MM-DD" (or none: assume
-- yes when the release year is not in the future).
function M.released(book, today)
    if type(book.release_date) == "string" and book.release_date ~= "" then
        return book.release_date <= today
    end
    local y = tonumber(book.release_year)
    return y == nil or y <= tonumber(today:sub(1, 4))
end

--- New books to download: by authors with auto-download on, out already,
-- not on the device and not tried before. books: the new releases found
-- in a sync (each with .why = author name or series name). opts:
-- has_file(book), tried (id -> time, updated), now, today, limit.
function M.autoPicks(books, s, opts)
    local auto = {}
    for _i, a in ipairs(M.list(s)) do
        if a.auto then auto[key(a.name)] = true end
    end
    if next(auto) == nil then return {} end
    local out = {}
    local tried = opts.tried or {}
    for _i, b in ipairs(books or {}) do
        local id = tostring(b.id)
        local by = false
        for name in tostring(b.authors or b.author or ""):gmatch("[^,]+") do
            if auto[key(name)] then by = true break end
        end
        if by and not tried[id] and M.released(b, opts.today) and not opts.has_file(b) then
            out[#out + 1] = b
            tried[id] = opts.now
            if #out >= (opts.limit or M.PER_SYNC) then break end
        end
    end
    return out
end

return M
