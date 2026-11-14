--[[--
Download history: every book downloaded (by hand or in the background), with
a search box and "Download again", which asks the same bot for the same file
and, when that bot is gone, finds another one that has the book.

Kept in its own file (settings/ircbooks_history.lua), not in KOReader's
settings.reader.lua, which is rewritten often.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local History = require("koirc/history")
local results = require("koirc/results")

local M = {}

local store = { file = nil, list = nil }

local function storePath()
    local dir = DataStorage.getSettingsDir and DataStorage:getSettingsDir()
             or (DataStorage:getDataDir() .. "/settings")
    return dir .. "/ircbooks_history.lua"
end

--- All records, newest first.
function M.list()
    if store.list then return store.list end
    local LuaSettings = require("luasettings")
    local ok, file = pcall(LuaSettings.open, LuaSettings, storePath())
    store.file = ok and file or nil
    store.list = store.file and store.file:readSetting("downloads") or {}
    return store.list
end

function M.setList(list)
    store.list = list or {}
    M.save()
end

function M.save()
    M.list()
    if not store.file then return end
    store.file:saveSetting("downloads", store.list)
    pcall(store.file.flush, store.file)
end

--- After a download: remember it.
function M.record(plugin, path, book, entry)
    if not entry then return end
    History.add(M.list(), History.make(path, book, entry, os.time()))
    M.save()
end

local function isFile(p) return p and lfs.attributes(p, "mode") == "file" end

local function itemsFor(list, filter)
    local items = {}
    for _i, r in ipairs(History.search(list, filter)) do
        local info = { os.date("%Y-%m-%d", r.at or 0) }
        if r.bot then info[#info + 1] = r.bot end
        if r.size then info[#info + 1] = r.size end
        items[#items + 1] = {
            text = (isFile(r.path) and "✓ " or "✗ ") .. (r.title or r.request or "?"),
            mandatory = table.concat(info, " · "),
            record = r,
        }
    end
    return items
end

local menu

local function refresh(plugin)
    if not menu then return end
    local list = M.list()
    local items = itemsFor(list, menu.filter)
    local title = menu.filter and menu.filter ~= "" and T(_("Download history: “%1”"), menu.filter) or _("Download history")
    if #items == 0 then
        items[1] = { text = #list == 0 and _("Nothing downloaded yet.") or _("No downloads match."), dim = true }
    end
    menu:switchItemTable(title, items, -1)
end

local function askFilter(plugin)
    local dialog
    dialog = InputDialog:new{
        title = _("Search download history"),
        input = menu and menu.filter or "",
        input_hint = _("title, author or bot"),
        buttons = {{
            { text = _("Show all"), callback = function()
                UIManager:close(dialog)
                if menu then menu.filter = nil refresh(plugin) end
            end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                if menu then menu.filter = text refresh(plugin) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Ask for the same file again (another bot when needed).
function M.downloadAgain(plugin, r)
    if plugin.queue:isRunning() then
        plugin:showQueueBusy()
        return
    end
    local entry = History.entry(r)
    local book = History.book(r)
    local dir = plugin:getDownloadDir()
    require("storage").guard(plugin, entry, function()
        NetworkMgr:runWhenOnline(function()
            plugin.hardcover:clearCurrent()
            plugin:doDownload(entry, dir, { book = book })
        end)
    end)
end

local function showRecord(plugin, r)
    local dialog
    local function button(text, fn)
        return { text = text, callback = function() UIManager:close(dialog) fn() end }
    end
    local have = isFile(r.path)
    local lines = { r.title or r.request }
    if r.author and r.author ~= "" then lines[#lines + 1] = r.author end
    lines[#lines + 1] = T(_("Downloaded %1 from %2"), os.date("%Y-%m-%d %H:%M", r.at or 0), r.bot or "?")
    lines[#lines + 1] = have and T(_("File: %1"), r.path) or _("The file is no longer on the device.")
    local rows = {}
    local first = {}
    if have then
        first[#first + 1] = button(_("Open"), function()
            if menu then UIManager:close(menu) menu = nil end
            plugin:openBook(r.path)
        end)
    end
    first[#first + 1] = button(_("Download again"), function() M.downloadAgain(plugin, r) end)
    rows[#rows + 1] = first
    rows[#rows + 1] = {
        button(_("Search again"), function()
            if menu then UIManager:close(menu) menu = nil end
            local q = History.query(r)
            plugin.hardcover:clearCurrent()
            plugin.last_query = q
            NetworkMgr:runWhenOnline(function() plugin:doSearch(q) end)
        end),
        button(_("Remove from history"), function()
            History.remove(M.list(), r)
            M.save()
            refresh(plugin)
        end),
    }
    rows[#rows + 1] = { button(_("Close"), function() end) }
    dialog = ButtonDialog:new{ title = table.concat(lines, "\n"), title_align = "left", buttons = rows }
    UIManager:show(dialog)
end

function M.show(plugin)
    if menu then UIManager:close(menu) end
    local m
    m = require("uiprefs").cover(Menu:new(require("uiprefs").apply(plugin.settings, {
        title = _("Download history"),
        subtitle = _("Tap a book; the search icon filters"),
        item_table = {},
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function() askFilter(plugin) end,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_m, item)
            if item.record then showRecord(plugin, item.record) end
            return true
        end,
        onMenuHold = function(_m, item)
            if item.record then
                UIManager:show(ConfirmBox:new{
                    text = T(_("Download “%1” again?"), item.record.title or item.record.request),
                    ok_text = _("Download"),
                    ok_callback = function() M.downloadAgain(plugin, item.record) end,
                })
            end
            return true
        end,
        close_callback = function()
            if menu == m then menu = nil end
            UIManager:close(m)
        end,
    })))
    menu = m
    refresh(plugin)
    UIManager:show(m)
end

--- How many downloads are recorded (for the menu).
function M.count()
    return #M.list()
end

return M
