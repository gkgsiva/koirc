--[[--
Which saved Hardcover data a sync has to load again, and in which batches.

Hardcover allows about 60 requests a minute. Loading every list and every
tracked series one by one went over that ("HTTP 429"), so a sync now:
- skips lists whose book count and last change are the same as last time,
- reloads series only every few days (followed series daily, for new
  releases), or when their book count changed,
- loads several lists or series in one request.

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local M = {}

-- Reload a list even when it looks unchanged after this long.
M.LIST_MAX_AGE = 3 * 86400
-- Series books change rarely.
M.SERIES_MAX_AGE = 7 * 86400
-- Followed series are checked for new releases.
M.FOLLOWED_MAX_AGE = 86400
-- Followed authors' new books, and reading goals.
M.EXTRA_MAX_AGE = 86400
M.GOALS_MAX_AGE = 6 * 3600
-- Lists and series loaded per request.
M.LIST_BATCH = 5
M.SERIES_BATCH = 8

--- What identifies the content of a list: its book count and last change.
function M.listFingerprint(l)
    if type(l) ~= "table" then return nil end
    return tostring(l.count or "?") .. "|" .. tostring(l.updated_at or "")
end

--- "list", "series", "status" or nil, and the id.
function M.kind(key)
    local kind, id = tostring(key):match("^books:([^:]+):(.+)$")
    if not kind then return nil end
    if kind ~= "series" and kind ~= "status" and kind ~= "new" then kind = "list" end
    return kind, tonumber(id) or id
end

--- Fingerprints for list and series keys, from the lists and series tracker
-- just loaded.
function M.fingerprints(lists, series)
    local fps = {}
    for _, l in ipairs(type(lists) == "table" and lists.lists or {}) do
        fps["books:list:" .. tostring(l.id)] = M.listFingerprint(l)
    end
    for _, part in ipairs({ "following", "started" }) do
        for _, sr in ipairs(type(series) == "table" and series[part] or {}) do
            if sr.count then fps["books:series:" .. tostring(sr.id)] = tostring(sr.count) end
        end
    end
    return fps
end

--- Is the saved copy of key still good? meta[key] = {at, fp}.
-- followed: set of series keys checked for new releases.
function M.fresh(key, old, meta, fps, now, followed)
    if old[key] == nil then return false end
    local m = meta[key]
    if type(m) ~= "table" or not m.at then return false end
    local kind = M.kind(key)
    if kind == "status" then return false end -- one cheap request; always current
    if fps[key] ~= nil and m.fp ~= fps[key] then return false end
    local max
    if kind == "list" then max = M.LIST_MAX_AGE
    elseif followed and followed[key] then max = M.FOLLOWED_MAX_AGE
    else max = M.SERIES_MAX_AGE end
    return now - m.at < max
end

--- Split keys into those to load and those to keep.
function M.plan(keys, old, meta, fps, now, followed)
    local todo, keep = {}, {}
    for _, key in ipairs(keys) do
        if M.fresh(key, old, meta or {}, fps or {}, now, followed) then keep[#keep + 1] = key
        else todo[#todo + 1] = key end
    end
    return todo, keep
end

--- Group keys into requests: {kind = "list"|"series"|"single", keys, ids}.
function M.batches(keys)
    local out, cur = {}, {}
    local function add(kind, key, id, size)
        local b = cur[kind]
        if not b or #b.keys >= size then
            b = { kind = kind, keys = {}, ids = {} }
            cur[kind] = b
            out[#out + 1] = b
        end
        b.keys[#b.keys + 1] = key
        b.ids[#b.ids + 1] = id
    end
    for _, key in ipairs(keys) do
        local kind, id = M.kind(key)
        if kind == "list" and type(id) == "number" then add("list", key, id, M.LIST_BATCH)
        elseif kind == "series" and type(id) == "number" then add("series", key, id, M.SERIES_BATCH)
        else out[#out + 1] = { kind = "single", keys = { key }, ids = { id } } end
    end
    return out
end

--- Has the stamp at meta[name] expired?
function M.due(meta, name, max_age, now)
    local m = type(meta) == "table" and meta[name]
    return type(m) ~= "table" or not m.at or now - m.at >= max_age
end

return M
