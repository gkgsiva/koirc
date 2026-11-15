--[[--
Mirror Hardcover lists and the series tracker into KOReader collections.

Only what this plugin added is ever taken out again: books you add to a
mirrored collection yourself stay, and collections you made are never
removed. `managed` (saved in the settings) remembers, per collection, the
files the plugin put there.

No KOReader dependencies, so it is tested in spec/run.lua. rc is an adapter
around KOReader's ReadCollection (see collections.lua):
    exists(name), ensure(name), has(name, path), add(name, path),
    remove(name, path), isEmpty(name), removeCollection(name)
]]

local M = {}

--- Collections that should exist: array of {name, books}, where books is an
-- array of Hardcover books ({id, ...}). files[tostring(id)] is the book's
-- attached file path (or false/nil), or files is a function(book) returning
-- the book's file on the device (attached or matched by name). exists(path)
-- checks the file is there.
-- Returns desired: name -> array of paths (in list order), and the order
-- of names.
function M.desired(groups, files, exists)
    local desired, names = {}, {}
    for _i, g in ipairs(groups) do
        local name = g.name and tostring(g.name):gsub("^%s+", ""):gsub("%s+$", "")
        if name and name ~= "" then
            local paths = desired[name]
            if not paths then
                paths = {}
                desired[name] = paths
                names[#names + 1] = name
            end
            local seen = {}
            for _k, p in ipairs(paths) do seen[p] = true end
            for _k, b in ipairs(g.books or {}) do
                local path
                if type(b) == "table" and b.id then
                    if type(files) == "function" then path = files(b) else path = files[tostring(b.id)] end
                end
                if path and not seen[path] and exists(path) then
                    seen[path] = true
                    paths[#paths + 1] = path
                end
            end
        end
    end
    return desired, names
end

--- Make the collections match desired. Returns the new managed table, a
-- set of the collection names that changed (nil when nothing changed), and
-- what changed in each: name -> {added = n, removed = n, created = bool,
-- deleted = bool}.
-- keep_empty: create collections with no books on the device yet (true for
-- all, or a set of names).
function M.apply(rc, desired, names, managed, keep_empty)
    managed = managed or {}
    local new_managed, changed, details = {}, {}, {}
    local any = false
    local function note(name, field)
        local d = details[name]
        if not d then d = { added = 0, removed = 0 } details[name] = d end
        if field == "added" or field == "removed" then d[field] = d[field] + 1 else d[field] = true end
    end
    for _i, name in ipairs(names) do
        local paths = desired[name]
        local mine, wanted = {}, {}
        for _k, path in ipairs(paths) do wanted[path] = true end
        local old = managed[name] or {}
        local keep = keep_empty == true or (type(keep_empty) == "table" and keep_empty[name])
        if #paths > 0 or keep then
            if not rc.exists(name) then
                rc.ensure(name)
                changed[name] = true
                any = true
                note(name, "created")
            end
            for _k, path in ipairs(paths) do
                if not rc.has(name, path) then
                    rc.add(name, path)
                    note(name, "added")
                    changed[name] = true
                    any = true
                    mine[path] = true
                elseif old[path] then
                    mine[path] = true -- added by us earlier
                end
            end
        end
        -- Books we added that are no longer in the Hardcover list.
        for path in pairs(old) do
            if not mine[path] and not wanted[path] and rc.exists(name) and rc.has(name, path) then
                rc.remove(name, path)
                note(name, "removed")
                changed[name] = true
                any = true
            end
        end
        new_managed[name] = mine
    end
    -- Lists deleted on Hardcover (or mirroring turned off).
    for name, old in pairs(managed) do
        if desired[name] == nil and rc.exists(name) then
            for path in pairs(old) do
                if rc.has(name, path) then
                    rc.remove(name, path)
                    note(name, "removed")
                    changed[name] = true
                    any = true
                end
            end
            if rc.isEmpty(name) then
                rc.removeCollection(name)
                note(name, "deleted")
                changed[name] = true
                any = true
            end
        end
    end
    return new_managed, any and changed or nil, details
end

--- Lines describing details from M.apply, in the order of names (then the
-- removed collections by name), at most max lines plus "and n more".
-- words: {added = fmt, removed = fmt, created = text, deleted = text,
-- more = fmt} so the caller can translate them.
function M.describe(details, names, max, words)
    local order, seen = {}, {}
    for _i, n in ipairs(names or {}) do
        if details[n] and not seen[n] then seen[n] = true order[#order + 1] = n end
    end
    local rest = {}
    for n in pairs(details) do if not seen[n] then rest[#rest + 1] = n end end
    table.sort(rest)
    for _i, n in ipairs(rest) do order[#order + 1] = n end
    local lines = {}
    max = max or 12
    for i, n in ipairs(order) do
        if i > max then
            lines[#lines + 1] = (words.more):gsub("%%1", tostring(#order - max))
            break
        end
        local d = details[n]
        local parts = {}
        if d.deleted then
            parts[#parts + 1] = words.deleted
        else
            if d.created then parts[#parts + 1] = words.created end
            if d.added > 0 then parts[#parts + 1] = (words.added):gsub("%%1", tostring(d.added)) end
            if d.removed > 0 then parts[#parts + 1] = (words.removed):gsub("%%1", tostring(d.removed)) end
        end
        lines[#lines + 1] = "• " .. n .. ": " .. table.concat(parts, ", ")
    end
    return lines
end

return M
