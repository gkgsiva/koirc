--[[--
IRC book search for KOReader.

Connects to an IRC ebook channel, sends "@search <query>", receives the
results file by DCC, lists the books, and downloads the chosen one by DCC into
the download folder.

@module koplugin.ircbooks
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- Plugin-local modules must be required while the plugin loader has our
-- folder on package.path, i.e. here at load time.
local Fetcher = require("koirc/fetcher")
local results = require("koirc/results")

local has_ssl, ssl = pcall(require, "ssl")
if not has_ssl then ssl = nil end

local SETTINGS_KEY = "ircbooks"

local DEFAULTS = {
    host = "irc.irchighway.net",
    port = 6667,
    tls = false,
    channel = "#ebooks",
    search_cmd = "@search",
    formats = "",
    password = "",
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function friendlySize(n)
    if not n or n <= 0 then return "?" end
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    if n >= 1024 then return string.format("%.0f KB", n / 1024) end
    return string.format("%d B", n)
end

local function isDir(path)
    return path and lfs.attributes(path, "mode") == "directory"
end

local IrcBooks = WidgetContainer:extend{
    name = "ircbooks",
    is_doc_only = false,
}

function IrcBooks:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    if not self.settings.nick or self.settings.nick == "" then
        math.randomseed(os.time())
        self.settings.nick = "koreader" .. math.random(1000, 9999)
        self:saveSettings()
    end
    self.work_dir = DataStorage:getDataDir() .. "/cache/ircbooks"
    self.fetcher = Fetcher.new{
        socket = socket,
        ssl = ssl,
        config = function() return self.settings end,
        work_dir = self.work_dir,
        log = function(line) logger.dbg("ircbooks:", line) end,
    }
    self.tick = function() self:onTick() end
    self.ui.menu:registerToMainMenu(self)
end

function IrcBooks:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function IrcBooks:getDownloadDir()
    local candidates = {
        self.settings.download_dir,
        G_reader_settings:readSetting("download_dir"),
        G_reader_settings:readSetting("home_dir"),
        Device.home_dir,
        DataStorage:getDataDir(),
    }
    for i = 1, #candidates do
        if isDir(candidates[i]) then return candidates[i] end
    end
    return DataStorage:getDataDir()
end

-------------------------------------------------------------------------------
-- Menu
-------------------------------------------------------------------------------

function IrcBooks:addToMainMenu(menu_items)
    menu_items.ircbooks = {
        text = _("IRC book search"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Search for a book…"),
                callback = function() self:showSearchDialog() end,
            },
            {
                text_func = function()
                    if self.fetcher:isConnected() then
                        return T(_("Disconnect from %1"), self.settings.host)
                    end
                    return _("Not connected")
                end,
                enabled_func = function() return self.fetcher.conn ~= nil end,
                callback = function()
                    self.fetcher:cancel()
                    self.fetcher:disconnect()
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = self:getSettingsMenu(),
            },
        },
    }
end

function IrcBooks:getSettingsMenu()
    local function valueItem(key, label, hint, opts)
        opts = opts or {}
        return {
            text_func = function()
                local v = self.settings[key]
                if opts.secret and v and v ~= "" then v = "••••" end
                if v == nil or v == "" then v = opts.empty or _("not set") end
                return T("%1: %2", label, tostring(v))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editSetting(key, label, hint, opts, touchmenu_instance)
            end,
        }
    end
    return {
        valueItem("host", _("Server"), "irc.irchighway.net", { reconnect = true }),
        valueItem("port", _("Port"), "6667", { number = true, reconnect = true }),
        {
            text = _("Use TLS (usually port 6697)"),
            enabled_func = function() return ssl ~= nil end,
            checked_func = function() return self.settings.tls end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.settings.tls = not self.settings.tls
                if self.settings.tls and tonumber(self.settings.port) == 6667 then
                    self.settings.port = 6697
                elseif not self.settings.tls and tonumber(self.settings.port) == 6697 then
                    self.settings.port = 6667
                end
                self:saveSettings()
                self:reconnectLater()
                touchmenu_instance:updateItems()
            end,
        },
        valueItem("nick", _("Nickname"), "koreader1234", { reconnect = true }),
        valueItem("password", _("Server password"), "", { secret = true, reconnect = true, empty = _("none"), allow_empty = true }),
        valueItem("channel", _("Channel"), "#ebooks", { reconnect = true }),
        valueItem("search_cmd", _("Search command"), "@search"),
        valueItem("formats", _("Only show formats"), "epub, mobi, pdf", { empty = _("all"), allow_empty = true }),
        {
            text_func = function()
                return T(_("Download folder: %1"), self:getDownloadDir())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local DownloadMgr = require("ui/downloadmgr")
                DownloadMgr:new{
                    onConfirm = function(path)
                        self.settings.download_dir = path
                        self:saveSettings()
                        touchmenu_instance:updateItems()
                    end,
                }:chooseDir(self:getDownloadDir())
            end,
        },
    }
end

function IrcBooks:reconnectLater()
    -- New connection settings are picked up on the next connection.
    if not self.fetcher:isBusy() then self.fetcher:disconnect() end
end

function IrcBooks:editSetting(key, label, hint, opts, touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = label,
        input = tostring(self.settings[key] or ""),
        input_hint = hint,
        input_type = opts.number and "number" or nil,
        text_type = opts.secret and "password" or nil,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = trim(dialog:getInputText())
                    if opts.number then
                        value = tonumber(value)
                        if not value or value < 1 or value > 65535 then
                            UIManager:show(InfoMessage:new{ text = _("Please enter a valid port number.") })
                            return
                        end
                    elseif value == "" and not opts.allow_empty then
                        UIManager:show(InfoMessage:new{ text = _("This setting cannot be empty.") })
                        return
                    end
                    if key == "channel" and value:sub(1, 1) ~= "#" and value:sub(1, 1) ~= "&" then
                        value = "#" .. value
                    end
                    if key == "nick" then value = value:gsub("[^%w%-%[%]\\`%^{}_|]", "") end
                    self.settings[key] = value
                    self:saveSettings()
                    if opts.reconnect then self:reconnectLater() end
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-------------------------------------------------------------------------------
-- Network loop and status display
-------------------------------------------------------------------------------

function IrcBooks:startTicking()
    UIManager:unschedule(self.tick)
    UIManager:scheduleIn(0.05, self.tick)
end

function IrcBooks:onTick()
    local ok, delay = pcall(self.fetcher.step, self.fetcher)
    if not ok then
        logger.err("ircbooks: error in network loop:", delay)
        local job = self.fetcher.job
        self.fetcher:cancel()
        self.fetcher:disconnect()
        self:closeStatus()
        if job then
            UIManager:show(InfoMessage:new{ text = T(_("Something went wrong:\n%1"), tostring(delay)) })
        end
        return
    end
    if delay then UIManager:scheduleIn(delay, self.tick) end
end

function IrcBooks:showStatus(text)
    self:closeStatus()
    local widget
    widget = InfoMessage:new{
        text = text .. "\n\n" .. _("Tap to cancel."),
        dismiss_callback = function()
            if self.status_widget == widget then
                self.status_widget = nil
                self.fetcher:cancel()
            end
        end,
    }
    self.status_widget = widget
    self.status_time = os.time()
    UIManager:show(widget)
end

function IrcBooks:showProgress(label, received, total)
    -- Avoid refreshing the e-ink screen for every chunk.
    local now = socket.gettime()
    if self.status_widget and self.progress_time and now - self.progress_time < 2 then return end
    self.progress_time = now
    local text
    if total and total > 0 then
        text = T(_("%1\n%2 of %3 (%4 %)"), label, friendlySize(received), friendlySize(total),
                 math.floor(received * 100 / total))
    else
        text = T(_("%1\n%2"), label, friendlySize(received))
    end
    self:showStatus(text)
end

function IrcBooks:closeStatus()
    local widget = self.status_widget
    self.status_widget = nil
    self.progress_time = nil
    if widget then UIManager:close(widget) end
end

function IrcBooks:showError(text)
    self:closeStatus()
    UIManager:show(InfoMessage:new{ text = text })
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------

function IrcBooks:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search IRC for books"),
        input = self.last_query or "",
        input_hint = _("Author and/or title"),
        description = T(_("Searching %1 on %2"), self.settings.channel, self.settings.host),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = trim(dialog:getInputText()):gsub("[\r\n]", " ")
                    if query == "" then return end
                    UIManager:close(dialog)
                    self.last_query = query
                    NetworkMgr:runWhenOnline(function() self:doSearch(query) end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function IrcBooks:doSearch(query)
    pcall(util.makePath, self.work_dir)
    local ok = self.fetcher:search(query, {
        on_status = function(text) self:showStatus(text) end,
        on_progress = function(received, total)
            self:showProgress(_("Receiving search results…"), received, total)
        end,
        on_done = function(list)
            self:closeStatus()
            self:showResults(query, list)
        end,
        on_error = function(err) self:showError(err) end,
    })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Another request is still running.") })
        return
    end
    self:startTicking()
end

function IrcBooks:showResults(query, list)
    if #list == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("No books found for “%1”."), query) })
        return
    end
    local shown = results.filter(list, self.settings.formats)
    if #shown == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Found %1 results for “%2”, but none in the formats: %3.\nChange “Only show formats” in the settings to see them."),
                     #list, query, self.settings.formats),
        })
        return
    end
    local items = {}
    for i = 1, #shown do
        local entry = shown[i]
        items[i] = {
            text = entry.title,
            mandatory = entry.size and T("%1 · %2", entry.size, entry.bot) or entry.bot,
            entry = entry,
        }
    end
    if self.results_menu then UIManager:close(self.results_menu) end
    local menu
    menu = Menu:new{
        title = T(_("%1 results for “%2”"), #shown, query),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        multilines_show_more_text = true,
        onMenuSelect = function(_menu, item)
            self:confirmDownload(item.entry)
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
            if self.results_menu == menu then self.results_menu = nil end
        end,
    }
    self.results_menu = menu
    UIManager:show(menu)
end

-------------------------------------------------------------------------------
-- Download
-------------------------------------------------------------------------------

function IrcBooks:confirmDownload(entry)
    local dir = self:getDownloadDir()
    local text = T(_("Download this book?\n\n%1\n\nSize: %2\nFrom: %3\nSave to: %4"),
                   entry.title, entry.size or _("unknown"), entry.bot, dir)
    if entry.ext == "rar" or entry.ext == "7z" then
        text = text .. "\n\n" .. _("Note: this is an archive that KOReader cannot open by itself.")
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function() self:doDownload(entry, dir) end)
        end,
    })
end

function IrcBooks:doDownload(entry, dir)
    local ok = self.fetcher:download(entry, dir, {
        on_status = function(text) self:showStatus(text) end,
        on_progress = function(received, total)
            self:showProgress(T(_("Downloading %1"), entry.title), received, total)
        end,
        on_done = function(path)
            self:closeStatus()
            self:onDownloaded(path)
        end,
        on_error = function(err) self:showError(err) end,
    })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Another request is still running.") })
        return
    end
    self:startTicking()
end

function IrcBooks:onDownloaded(path)
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
    local DocumentRegistry = require("document/documentregistry")
    if not DocumentRegistry:hasProvider(path) then
        UIManager:show(InfoMessage:new{ text = T(_("Saved to:\n%1"), path) })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Saved to:\n%1\n\nOpen it now?"), path),
        ok_text = _("Open"),
        cancel_text = _("Later"),
        ok_callback = function()
            if self.results_menu then
                UIManager:close(self.results_menu)
                self.results_menu = nil
            end
            if self.ui.document and self.ui.switchDocument then
                self.ui:switchDocument(path)
            else
                local ReaderUI = require("apps/reader/readerui")
                ReaderUI:showReader(path)
            end
        end,
    })
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function IrcBooks:stopAll()
    UIManager:unschedule(self.tick)
    self.fetcher:cancel()
    self.fetcher:disconnect("bye")
    self:closeStatus()
end

function IrcBooks:onSuspend()
    self:stopAll()
end

function IrcBooks:onNetworkDisconnected()
    if self.fetcher.conn then self:stopAll() end
end

function IrcBooks:onCloseWidget()
    self:stopAll()
end

return IrcBooks
