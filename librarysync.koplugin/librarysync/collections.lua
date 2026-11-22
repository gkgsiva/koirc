--[[--
Mirror the Library's shelves (lists, collections and your own folders) and series into
KOReader collections, holding the books of each that are on the device. Read them from
KOReader's collections view (in ZenOS: the Collections tab).

Only what this plugin added is ever taken out again: books you add to a mirrored collection
yourself stay, and collections you made are never removed. `managed` (saved in
settings/librarysync_collections.lua) remembers, per collection, the files the plugin put there.

The planning part (groups, desired, apply) has no KOReader dependencies and is tested in
spec/run.lua; KOReader's ReadCollection is used through a small adapter:
    exists(name), ensure(name), has(name, path), add(name, path), remove(name, path),
    isEmpty(name), removeCollection(name)
]]

local util = require("librarysync/util")

local M = {}

-- Folder kinds that are shelves. Series folders come from the "series" choice instead, and the
-- server's "Files in no other folder" is not a shelf.
local SHELF = { list = true, collection = true, own = true }

local function num(n) return tonumber(n or "") or math.huge end

--- Groups to mirror: { {name=, books={catalog books, in order}} }.
-- mode: "shelves", "series" or "both".
function M.groups(cat, mode)
    local out = {}
    if not (cat and cat.books) then return out end
    if mode == "shelves" or mode == "both" then
        local by = {}
        for _, b in ipairs(cat.books) do
            for _, f in ipairs(b.folders or {}) do
                by[f] = by[f] or {}
                table.insert(by[f], b)
            end
        end
        for _, f in ipairs(cat.folders or {}) do
            -- unknown kind (older server): every folder but the series ones is a shelf
            local shelf = f.kind and SHELF[f.kind] or (not f.kind)
            if shelf and by[f.name] then
                local books = by[f.name]
                table.sort(books, function(a, b) return (a.title or ""):lower() < (b.title or ""):lower() end)
                out[#out + 1] = { name = f.name, books = books, folder = f.name }
            end
        end
    end
    if mode == "series" or mode == "both" then
        local by, order = {}, {}
        for _, b in ipairs(cat.books) do
            if b.series and b.series ~= "" then
                if not by[b.series] then by[b.series] = {} order[#order + 1] = b.series end
                table.insert(by[b.series], b)
            end
        end
        table.sort(order, function(a, b) return a:lower() < b:lower() end)
        for _, name in ipairs(order) do
            local books = by[name]
            table.sort(books, function(a, b)
                if num(a.number) ~= num(b.number) then return num(a.number) < num(b.number) end
                return (a.title or "") < (b.title or "")
            end)
            out[#out + 1] = { name = name, books = books }
        end
    end
    return out
end

--- The file of a catalog book on the device: the copy in folder (if given), else any copy the
-- sync recorded. exists(path) checks it is there.
function M.local_file(cfg, state, book, folder, exists)
    for _, f in ipairs(book.files or {}) do
        local rec = state.files and state.files[f.key]
        if rec then
            if folder then
                local p = cfg.base .. "/" .. util.safe_name(folder, "Folder") .. "/" .. f.name
                if rec[p] and exists(p) then return p end
            end
            local paths = {}
            for p in pairs(rec) do paths[#paths + 1] = p end
            table.sort(paths)
            for _, p in ipairs(paths) do if exists(p) then return p end end
        end
    end
end

--- Collections that should exist: name -> array of paths (in order), and the order of names.
function M.desired(cfg, state, groups, exists)
    local desired, names = {}, {}
    for _, g in ipairs(groups) do
        local name = util.trim(tostring(g.name or ""))
        if name ~= "" then
            local paths = desired[name]
            if not paths then
                paths = {}
                desired[name] = paths
                names[#names + 1] = name
            end
            local seen = {}
            for _, p in ipairs(paths) do seen[p] = true end
            for _, b in ipairs(g.books or {}) do
                local p = M.local_file(cfg, state, b, g.folder, exists)
                if p and not seen[p] then
                    seen[p] = true
                    paths[#paths + 1] = p
                end
            end
        end
    end
    return desired, names
end

--- Make the collections match desired. Collections with no book on the device are not made.
-- Returns the new managed table, the set of changed names (nil when nothing changed), and
-- per name { added = n, removed = n, created = bool, deleted = bool }.
function M.apply(rc, desired, names, managed)
    managed = managed or {}
    local new_managed, changed, details = {}, {}, {}
    local any = false
    local function note(name, field)
        local d = details[name]
        if not d then d = { added = 0, removed = 0 } details[name] = d end
        if field == "added" or field == "removed" then d[field] = d[field] + 1 else d[field] = true end
        changed[name] = true
        any = true
    end
    for _, name in ipairs(names) do
        local paths = desired[name]
        local mine, wanted = {}, {}
        for _, p in ipairs(paths) do wanted[p] = true end
        local old = managed[name] or {}
        if #paths > 0 then
            if not rc.exists(name) then rc.ensure(name) note(name, "created") end
            for _, p in ipairs(paths) do
                if not rc.has(name, p) then
                    rc.add(name, p)
                    note(name, "added")
                    mine[p] = true
                elseif old[p] then
                    mine[p] = true
                end
            end
        end
        for p in pairs(old) do
            if not wanted[p] and rc.exists(name) and rc.has(name, p) then
                rc.remove(name, p)
                note(name, "removed")
            end
        end
        if #paths == 0 and rc.exists(name) and next(old) and rc.isEmpty(name) then
            rc.removeCollection(name)
            note(name, "deleted")
        end
        if next(mine) then new_managed[name] = mine end
    end
    -- shelves or series gone from the Library (or mirroring turned off)
    for name, old in pairs(managed) do
        if desired[name] == nil and rc.exists(name) then
            for p in pairs(old) do
                if rc.has(name, p) then rc.remove(name, p) note(name, "removed") end
            end
            if rc.isEmpty(name) then rc.removeCollection(name) note(name, "deleted") end
        end
    end
    return new_managed, any and changed or nil, details
end

--- One line per changed collection, at most max, then "and n more".
function M.describe(details, names, max)
    local order, seen = {}, {}
    for _, n in ipairs(names or {}) do
        if details[n] and not seen[n] then seen[n] = true order[#order + 1] = n end
    end
    local rest = {}
    for n in pairs(details) do if not seen[n] then rest[#rest + 1] = n end end
    table.sort(rest)
    for _, n in ipairs(rest) do order[#order + 1] = n end
    local lines = {}
    for i, n in ipairs(order) do
        if i > (max or 12) then
            lines[#lines + 1] = string.format("… and %d more", #order - (max or 12))
            break
        end
        local d, parts = details[n], {}
        if d.deleted then
            parts[#parts + 1] = "removed"
        else
            if d.created then parts[#parts + 1] = "new" end
            if d.added > 0 then parts[#parts + 1] = "+" .. d.added end
            if d.removed > 0 then parts[#parts + 1] = "−" .. d.removed end
        end
        lines[#lines + 1] = "• " .. n .. ": " .. table.concat(parts, ", ")
    end
    return lines
end

--- KOReader's collections with the API this needs (KOReader 2024.04 and newer), or nil.
function M.readCollection()
    local ok, RC = pcall(require, "readcollection")
    if not ok or type(RC) ~= "table" or type(RC.coll) ~= "table" then return nil end
    if not RC.addCollection or not RC.addItem or not RC.removeItem or not RC.write then return nil end
    return RC
end

function M.adapter(RC)
    local ok, ffiutil = pcall(require, "ffi/util")
    local reals = {}
    local function real(p)
        local r = reals[p]
        if r then return r end
        r = ok and ffiutil.realpath and ffiutil.realpath(p) or p
        reals[p] = r
        return r
    end
    return {
        exists = function(name) return RC.coll[name] ~= nil end,
        ensure = function(name) if not RC.coll[name] then RC:addCollection(name) end end,
        has = function(name, p)
            local c = RC.coll[name]
            return c ~= nil and (c[p] ~= nil or c[real(p)] ~= nil)
        end,
        add = function(name, p) RC:addItem(real(p), name) end,
        remove = function(name, p)
            local c = RC.coll[name]
            if not c then return end
            if c[p] then c[p] = nil else RC:removeItem(real(p), name, true) end
        end,
        isEmpty = function(name) return next(RC.coll[name] or {}) == nil end,
        removeCollection = function(name)
            if RC.removeCollection then RC:removeCollection(name) else RC.coll[name] = nil end
        end,
    }
end

--- Bring the KOReader collections up to date. mode: "off" removes the mirrored ones.
-- Returns changed count, details, names; or nil, error.
function M.mirror(cfg, mode, managed_path, rc_override)
    local RC = rc_override and true or M.readCollection()
    if not RC then return nil, "This KOReader version has no named collections. Update KOReader to use this." end
    local rc = rc_override or M.adapter(RC)
    local desired, names = {}, {}
    if mode ~= "off" then
        local cat = util.load_table(cfg.catalog_path)
        local state = util.load_table(cfg.state_path) or {}
        local exists = function(p) return (util.file_size(p) or 0) > 0 end
        desired, names = M.desired(cfg, state, M.groups(cat, mode), exists)
    end
    local managed = util.load_table(managed_path) or {}
    local new_managed, changed, details = M.apply(rc, desired, names, managed)
    util.save_table(managed_path, new_managed)
    if not changed then return 0, {}, names end
    local n = 0
    for _ in pairs(changed) do n = n + 1 end
    if not rc_override then
        local ok, err = pcall(RC.write, RC, changed)
        if not ok then return nil, tostring(err) end
    end
    return n, details, names
end

return M
