--[[--
Back up and restore the plugin's settings (filters, folders, network, Hardcover
options), its library (saved Hardcover lists and attached books) and the
download history, all in one file.

The Hardcover API key and the IRC server password are never written to the
backup; restoring keeps the ones already on the device.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local BackupData = require("koirc/backupdata")

local M = {}

local function pluginVersion(plugin)
    local v
    pcall(function() v = dofile(plugin.path .. "/_meta.lua").version end)
    return v
end

--- Write the backup into the download folder. Returns the path.
function M.write(plugin, dir)
    local HistoryUI = require("historyui")
    local hc = plugin.hardcover
    local data = BackupData.build{
        settings = plugin.settings,
        library = hc:cache(),
        collections = hc:storeValue("collections"),
        history = HistoryUI.list(),
        version = pluginVersion(plugin),
        now = os.time(),
    }
    local path = string.format("%s/%s-%s.lua", dir, BackupData.PREFIX, os.date("%Y-%m-%d"))
    local LuaSettings = require("luasettings")
    if lfs.attributes(path, "mode") then os.remove(path) end
    local file = LuaSettings:open(path)
    for k, v in pairs(data) do file:saveSetting(k, v) end
    file:flush()
    return path
end

function M.export(plugin)
    local dir = plugin:getDownloadDir()
    local ok, res = pcall(M.write, plugin, dir)
    if not ok then
        logger.err("ircbooks: backup failed:", res)
        UIManager:show(InfoMessage:new{ text = T(_("Could not write the backup:\n%1"), tostring(res)) })
        return
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Backup saved to:\n%1\n\nIt holds your settings, filters, folders, saved Hardcover lists, attached books and download history. Your Hardcover API key and server password are not included."), res),
    })
end

--- Read a backup file. Returns the data table or nil, error.
function M.read(path)
    local LuaSettings = require("luasettings")
    local ok, file = pcall(LuaSettings.open, LuaSettings, path)
    if not ok or not file then return nil, _("Cannot read this file.") end
    local data = file.data
    if not BackupData.isBackup(data) then return nil, _("This is not an IRC book search backup.") end
    return data
end

function M.restore(plugin, data)
    local HistoryUI = require("historyui")
    local hc = plugin.hardcover
    BackupData.mergeSettings(plugin.settings, data.settings)
    plugin:saveSettings()
    if type(data.library) == "table" then hc:setCache(data.library) end
    if type(data.collections) == "table" then hc:setStoreValue("collections", data.collections) end
    if type(data.history) == "table" then HistoryUI.setList(data.history) end
    hc:forgetFiles()
    pcall(function() require("collections").mirrorSoon(hc, 1) end)
end

function M.import(plugin)
    local PathChooser = require("ui/widget/pathchooser")
    local chooser = PathChooser:new{
        title = _("Choose a backup file"),
        select_directory = false,
        select_file = true,
        show_files = true,
        path = plugin:getDownloadDir(),
        file_filter = function(name) return name:match("%.lua$") ~= nil end,
        onConfirm = function(path)
            local data, err = M.read(path)
            if not data then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("Restore the backup from %1?\n\nYour current settings, saved Hardcover lists and download history are replaced. Your API key and server password stay as they are."),
                         os.date("%Y-%m-%d %H:%M", tonumber(data.created) or 0)),
                ok_text = _("Restore"),
                ok_callback = function()
                    local ok, rerr = pcall(M.restore, plugin, data)
                    if ok then
                        UIManager:show(InfoMessage:new{ text = _("Backup restored."), timeout = 3 })
                    else
                        logger.err("ircbooks: restore failed:", rerr)
                        UIManager:show(InfoMessage:new{ text = T(_("Could not restore:\n%1"), tostring(rerr)) })
                    end
                end,
            })
        end,
    }
    UIManager:show(chooser)
end

return M
