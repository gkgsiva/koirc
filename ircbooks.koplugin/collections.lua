--[[--
Keep KOReader collections in step with Hardcover: one collection per
Hardcover list and per series in the series tracker, holding the books of
that list or series that are on the device. Read from KOReader's own
collections view; use the Hardcover view only to find and download books.

Runs after "Sync with Hardcover" (also the background sync), after
downloads and after "Refresh attached books". Only the books this plugin
added are ever removed again (see koirc/collsync.lua).
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local CollSync = require("koirc/collsync")

local M = {}

-- Series from the tracker mirrored at most (and loaded during a sync).
M.MAX_SERIES = 60

local function isFile(p) return p and lfs.attributes(p, "mode") == "file" end

--- KOReader's collections with the API this needs (KOReader 2024.04 and
-- newer, which has several named collections), or nil.
local function readCollection()
    local ok, RC = pcall(require, "readcollection")
    if not ok or type(RC) ~= "table" or type(RC.coll) ~= "table" then return nil end
    if not RC.addCollection or not RC.addItem or not RC.removeItem or not RC.write then return nil end
    return RC
end

function M.available()
    return readCollection() ~= nil
end

local function adapter(RC)
    local ok, ffiutil = pcall(require, "ffi/util")
    local function real(p)
        if ok and ffiutil.realpath then return ffiutil.realpath(p) or p end
        return p
    end
    return {
        exists = function(name) return RC.coll[name] ~= nil end,
        ensure = function(name) if not RC.coll[name] then RC:addCollection(name) end end,
        has = function(name, path)
            local c = RC.coll[name]
            return c ~= nil and (c[path] ~= nil or c[real(path)] ~= nil)
        end,
        add = function(name, path) RC:addItem(real(path), name) end,
        remove = function(name, path)
            local c = RC.coll[name]
            if not c then return end
            if c[path] then c[path] = nil else RC:removeItem(real(path), name, true) end
        end,
        isEmpty = function(name) return next(RC.coll[name] or {}) == nil end,
        removeCollection = function(name)
            if RC.removeCollection then RC:removeCollection(name) else RC.coll[name] = nil end
        end,
    }
end

--- Lists and tracker series saved from Hardcover, with their books:
-- array of {name, books, key}. Lists first, in Hardcover's order.
function M.groups(cache)
    local out = {}
    local lists = type(cache.lists) == "table" and cache.lists.lists or {}
    for _i, l in ipairs(lists) do
        out[#out + 1] = { name = l.name, key = "books:list:" .. tostring(l.id), books = cache["books:list:" .. tostring(l.id)] }
    end
    local series = type(cache.series) == "table" and cache.series or {}
    local seen, n = {}, 0
    for _k, part in ipairs({ series.following or {}, series.started or {} }) do
        for _i, sr in ipairs(part) do
            if not seen[sr.id] and n < M.MAX_SERIES then
                seen[sr.id] = true
                n = n + 1
                out[#out + 1] = { name = sr.name, key = "books:series:" .. tostring(sr.id), books = cache["books:series:" .. tostring(sr.id)] }
            end
        end
    end
    return out
end

--- Cache keys a sync should load so every mirrored list and series has its
-- books (lists not opened yet in the Hardcover view aren't saved otherwise).
function M.syncKeys(fresh)
    local keys = {}
    for _i, g in ipairs(M.groups(fresh)) do keys[#keys + 1] = g.key end
    return keys
end

function M.enabled(settings)
    return settings.collections_sync ~= false
end

--- Bring the collections up to date. hc: the HardcoverUI. off: remove the
-- mirrored collections instead. Returns the number of collections changed,
-- or nil + error.
function M.mirror(hc, off)
    local s = hc:settings()
    if not off and not M.enabled(s) then return 0 end
    local RC = readCollection()
    if not RC then return nil, _("This KOReader version has no collections that can be named. Update KOReader to use this.") end
    local desired, names = {}, {}
    if not off then
        desired, names = CollSync.desired(M.groups(hc:cache()), s.hardcover_files or {}, isFile)
    end
    -- Kept with the Hardcover data, not in settings.reader.lua (it can list
    -- hundreds of files).
    local managed, changed = CollSync.apply(adapter(RC), desired, names, hc:storeValue("collections") or {})
    if changed or not hc:storeValue("collections") then hc:setStoreValue("collections", managed) end
    if not changed then return 0 end
    local n = 0
    for _k in pairs(changed) do n = n + 1 end
    local ok, err = pcall(RC.write, RC, changed)
    if not ok then
        logger.warn("ircbooks: could not save collections:", err)
        return nil, tostring(err)
    end
    -- An open collections list shows the change when it is opened again.
    logger.info("ircbooks: collections updated:", n)
    return n
end

-- Calls close together (several downloads, a sync) are done once.
local pending = false

--- Mirror a moment later, without blocking the caller.
function M.mirrorSoon(hc, delay)
    if pending or not M.enabled(hc:settings()) then return end
    pending = true
    UIManager:scheduleIn(delay or 2, function()
        pending = false
        local ok, n, err = pcall(M.mirror, hc)
        if not ok then logger.warn("ircbooks: collections mirror failed:", n)
        elseif not n then logger.warn("ircbooks: collections mirror:", err) end
    end)
end

--- Settings menu entry.
function M.getSettingsItem(hc)
    return {
        text = _("Mirror Hardcover lists and series tracker as KOReader collections"),
        help_text = _("Each Hardcover list and each series in your series tracker becomes a KOReader collection holding the books you have on the device. Read from KOReader's collections; use the Hardcover view to download. Books you add to these collections yourself are kept."),
        checked_func = function() return M.enabled(hc:settings()) end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local s = hc:settings()
            local on = not M.enabled(s)
            s.collections_sync = on
            hc.plugin:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
            local ok, n, err = pcall(M.mirror, hc, not on)
            if not ok then err = n n = nil end
            if not n then
                UIManager:show(InfoMessage:new{ text = tostring(err) })
            elseif on then
                UIManager:show(InfoMessage:new{
                    text = T(_("%1 collections updated.\n\nRun “Sync with Hardcover” once to load the books of lists you haven't opened yet."), n),
                })
            else
                UIManager:show(InfoMessage:new{ text = _("Mirrored collections removed. Books you added yourself are kept."), timeout = 3 })
            end
        end,
    }
end

return M
