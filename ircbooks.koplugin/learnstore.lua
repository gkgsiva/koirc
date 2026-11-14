--[[--
Small data the plugin learns while it is used: bot health, the formats and
bots picked by hand, and the books finished per year (reading goals). Kept in
its own file, settings/ircbooks_learn.lua, not in settings.reader.lua, which
KOReader rewrites often. Saved a few seconds after a change, never on the
suspend or close paths.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local BotHealth = require("koirc/bothealth")

local M = {}

-- One copy for the whole session (file browser and reader instances).
local Store = { file = nil, data = nil, health = nil, pending = false }

local function path()
    local dir = DataStorage.getSettingsDir and DataStorage:getSettingsDir()
             or (DataStorage:getDataDir() .. "/settings")
    return dir .. "/ircbooks_learn.lua"
end

function M.data()
    if Store.data then return Store.data end
    local LuaSettings = require("luasettings")
    local ok, file = pcall(LuaSettings.open, LuaSettings, path())
    Store.file = ok and file or nil
    Store.data = {
        health = Store.file and Store.file:readSetting("health") or {},
        finished = Store.file and Store.file:readSetting("finished") or {},
    }
    return Store.data
end

--- The shared bot health / picks tracker.
function M.health()
    if not Store.health then Store.health = BotHealth.new(M.data().health) end
    return Store.health
end

--- Save in a few seconds (several changes close together are saved once).
function M.saveSoon()
    if Store.pending then return end
    Store.pending = true
    UIManager:scheduleIn(5, function()
        Store.pending = false
        M.save()
    end)
end

function M.save()
    local d = M.data()
    if not Store.file then return end
    Store.file:saveSetting("health", d.health)
    Store.file:saveSetting("finished", d.finished)
    local ok, err = pcall(Store.file.flush, Store.file)
    if not ok then logger.warn("ircbooks: could not save learned data:", err) end
end

--- Remember that a book was finished (for the yearly reading goal).
-- Each file counts once per year.
function M.bookFinished(file, title)
    if not file then return end
    local d = M.data()
    local year = os.date("%Y")
    d.finished[year] = d.finished[year] or {}
    if d.finished[year][file] then return end
    d.finished[year][file] = { title = title, at = os.time() }
    M.saveSoon()
end

--- Books finished in a year: count and list of {title, at}.
function M.finishedIn(year)
    local list = {}
    for file, e in pairs(M.data().finished[tostring(year)] or {}) do
        list[#list + 1] = { file = file, title = type(e) == "table" and e.title or nil, at = type(e) == "table" and e.at or 0 }
    end
    table.sort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)
    return #list, list
end

return M
