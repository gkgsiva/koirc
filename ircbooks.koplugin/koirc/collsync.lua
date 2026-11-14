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

--- Make the collections match desired. Returns the new managed table and a
-- set of the collection names that changed (nil when nothing changed).
-- keep_empty: create collections with no books on the device yet (true for
-- all, or a set of names).
function M.apply(rc, desired, names, managed, keep_empty)
    managed = managed or {}
    local new_managed, changed = {}, {}
    local any = false
    for _i, name in ipairs(names) do
        local paths = desired[name]
        local mine = {}
        local old = managed[name] or {}
        local keep = keep_empty == true or (type(keep_empty) == "table" and keep_empty[name])
        if #paths > 0 or keep then
            if not rc.exists(name) then
                rc.ensure(name)
                changed[name] = true
                any = true
            end
            for _k, path in ipairs(paths) do
                if not rc.has(name, path) then
                    rc.add(name, path)
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
            if not mine[path] and rc.exists(name) and rc.has(name, path) then
                local still = false
                for _k, p in ipairs(paths) do if p == path then still = true break end end
                if not still then
                    rc.remove(name, path)
                    changed[name] = true
                    any = true
                end
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
                    changed[name] = true
                    any = true
                end
            end
            if rc.isEmpty(name) then
                rc.removeCollection(name)
                changed[name] = true
                any = true
            end
        end
    end
    return new_managed, any and changed or nil
end

return M
