--[[--
Moving a book file: pick a free name in the new folder, and point every
record the plugin keeps at the new path (attached Hardcover books, download
history, collections the plugin manages). No KOReader dependencies (tested in
spec/run.lua); the moving itself is in filemove.lua.
]]

local M = {}

--- Folder and file name of path.
function M.split(path)
    local dir, name = tostring(path or ""):match("^(.*)/([^/]+)$")
    if not dir then return nil, path end
    if dir == "" then dir = "/" end
    return dir, name
end

--- path without a trailing slash (but "/" stays "/").
function M.cleanDir(dir)
    dir = tostring(dir or "")
    if #dir > 1 then dir = dir:gsub("/+$", "") end
    return dir
end

--- A path in dir for a file called name that does not exist yet:
-- "name.epub", then "name (2).epub", "name (3).epub"...
function M.target(dir, name, exists)
    dir = M.cleanDir(dir)
    local sep = dir:sub(-1) == "/" and "" or "/"
    local target = dir .. sep .. name
    local base, ext = name:match("^(.*)(%.[^.]+)$")
    local n = 2
    while exists(target) do
        target = dir .. sep .. (base or name) .. " (" .. n .. ")" .. (ext or "")
        n = n + 1
    end
    return target
end

--- True when the file at path is already in dir.
function M.sameDir(path, dir)
    local d = M.split(path)
    return d ~= nil and M.cleanDir(d) == M.cleanDir(dir)
end

--- map: key -> path. Every value equal to old becomes new. Returns the
-- number changed.
function M.replaceValues(map, old, new)
    if type(map) ~= "table" then return 0 end
    local n = 0
    for k, v in pairs(map) do
        if v == old then
            map[k] = new
            n = n + 1
        end
    end
    return n
end

--- Download history records: path old becomes new. Returns the number
-- changed.
function M.history(list, old, new)
    if type(list) ~= "table" then return 0 end
    local n = 0
    for _i, r in ipairs(list) do
        if type(r) == "table" and r.path == old then
            r.path = new
            n = n + 1
        end
    end
    return n
end

--- Collections the plugin manages: name -> set of paths. The key old
-- becomes new in each. Returns the number changed.
function M.managed(managed, old, new)
    if type(managed) ~= "table" then return 0 end
    local n = 0
    for _name, set in pairs(managed) do
        if type(set) == "table" and set[old] ~= nil then
            set[new] = set[old]
            set[old] = nil
            n = n + 1
        end
    end
    return n
end

--- Text safe as a folder or file name: no slashes, colons and such, at
-- most 80 bytes.
function M.cleanName(s)
    s = tostring(s or ""):gsub("[%c/\\:%*%?\"<>|]", " "):gsub("%s+", " ")
    s = s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if #s > 80 then s = s:sub(1, 80):gsub("[\192-\255][\128-\191]*$", ""):gsub("%s+$", "") end
    return s
end

--- Series name of a book: series_name, or series without its "#3".
function M.seriesName(info)
    local series = M.cleanName(info.series_name)
    if series == "" and info.series then series = M.cleanName((tostring(info.series):gsub("%s*#.*$", ""))) end
    return series
end

--- The folder a book goes in when filed by mode ("none", "author",
-- "series" or "author_series") under root. info: {author, series_name or
-- series}. Missing parts are left out (no "Unknown" folders).
function M.organisedDir(root, mode, info)
    local folder = M.cleanDir(root)
    if folder == "/" then folder = "" end
    info = info or {}
    local author = M.cleanName(info.author)
    local series = M.seriesName(info)
    if (mode == "author" or mode == "author_series") and author ~= "" then folder = folder .. "/" .. author end
    if (mode == "series" or mode == "author_series") and series ~= "" then folder = folder .. "/" .. series end
    if folder == "" then folder = "/" end
    return folder
end

--- Where each book goes when several are moved or filed. files: array of
-- {path, info}. dest: a folder (mode nil: all go there) or the root for
-- mode ("author", "series", "author_series"). Books already in place are
-- left out. Returns an array of {path, dir}.
function M.plan(files, dest, mode)
    local out = {}
    for _i, f in ipairs(files or {}) do
        local dir = mode and M.organisedDir(dest, mode, f.info) or M.cleanDir(dest)
        if f.path and not M.sameDir(f.path, dir) then out[#out + 1] = { path = f.path, dir = dir } end
    end
    return out
end

return M
