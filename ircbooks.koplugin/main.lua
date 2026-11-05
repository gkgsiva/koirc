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
local HardcoverUI = require("hardcoverui")

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

-- Well known ebook channels. Picking one fills in server, channel and search
-- command; each value can still be changed afterwards.
local PRESETS = {
    { name = "IRCHighway #ebooks", host = "irc.irchighway.net", channel = "#ebooks", search_cmd = "@search" },
    { name = "IRCHighway #bookz", host = "irc.irchighway.net", channel = "#bookz", search_cmd = "@search" },
    { name = "Undernet #bookz", host = "irc.undernet.org", channel = "#bookz", search_cmd = "@search" },
    { name = "Undernet #ebooks", host = "irc.undernet.org", channel = "#ebooks", search_cmd = "@search" },
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
    self.hardcover = HardcoverUI.new(self)
    if not self.ui.document then self.hardcover:maybeOpenAtStart() end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Actions for gestures, and for launchers such as ZenOS that hide the
-- regular menu tabs.
function IrcBooks:onDispatcherRegisterActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok then return end
    Dispatcher:registerAction("ircbooks_search", {
        category = "none", event = "IrcBooksSearch", title = _("IRC book search"), general = true,
    })
    Dispatcher:registerAction("ircbooks_settings", {
        category = "none", event = "IrcBooksSettings", title = _("IRC book search settings"), general = true,
    })
    Dispatcher:registerAction("ircbooks_hardcover", {
        category = "none", event = "IrcBooksHardcover", title = _("IRC book search: Hardcover lists"), general = true,
    })
end

function IrcBooks:onIrcBooksHardcover()
    self.hardcover:open()
    return true
end

function IrcBooks:onIrcBooksSearch()
    self:showSearchDialog()
    return true
end

function IrcBooks:onIrcBooksSettings()
    self:showSettingsDialog()
    return true
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
                text = _("Hardcover lists…"),
                callback = function() self.hardcover:open() end,
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
    local preset_items = {}
    for i = 1, #PRESETS do
        local p = PRESETS[i]
        preset_items[i] = {
            text = p.name,
            radio = true,
            checked_func = function()
                return self.settings.host == p.host and self.settings.channel == p.channel
            end,
            callback = function()
                self.settings.host = p.host
                self.settings.channel = p.channel
                self.settings.search_cmd = p.search_cmd
                self.settings.port = self.settings.tls and 6697 or 6667
                self.settings.password = ""
                self:saveSettings()
                self:reconnectLater()
            end,
        }
    end
    return {
        {
            text_func = function()
                for i = 1, #PRESETS do
                    local p = PRESETS[i]
                    if self.settings.host == p.host and self.settings.channel == p.channel then
                        return T(_("Network: %1"), p.name)
                    end
                end
                return T(_("Network: %1"), _("custom"))
            end,
            sub_item_table = preset_items,
            separator = true,
        },
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
            separator = true,
        },
        self.hardcover:getSettingsItem(),
        self.hardcover:getStartupItem(),
    }
end

--- Settings as a dialog, reachable without the main menu (from the search
-- dialog or a gesture/launcher action). Reuses the settings menu items.
function IrcBooks:showSettingsDialog(items, title)
    local ButtonDialog = require("ui/widget/buttondialog")
    items = items or self:getSettingsMenu()
    local dialog
    local reopen = { updateItems = function() self:showSettingsDialog() end }
    local buttons = {}
    for i = 1, #items do
        local item = items[i]
        local text = item.text_func and item.text_func() or item.text
        if item.checked_func then
            text = text .. (item.checked_func() and "  ✓" or "")
        end
        buttons[#buttons + 1] = {{
            text = text,
            align = "left",
            enabled = not item.enabled_func or item.enabled_func(),
            callback = function()
                UIManager:close(dialog)
                if item.sub_item_table then
                    self:showSettingsDialog(item.sub_item_table, text)
                else
                    item.callback(reopen)
                    if item.radio then self:showSettingsDialog() end
                end
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = title or _("IRC book search settings"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
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
    self.hardcover:clearCurrent()
    local dialog
    dialog = InputDialog:new{
        title = _("Search IRC for books"),
        input = self.last_query or "",
        input_hint = _("Author and/or title"),
        description = T(_("Searching %1 on %2"), self.settings.channel, self.settings.host),
        buttons = {{
            {
                text = _("Hardcover lists"),
                callback = function()
                    UIManager:close(dialog)
                    self.hardcover:open()
                end,
            },
        }, {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Settings"),
                callback = function()
                    UIManager:close(dialog)
                    self:showSettingsDialog()
                end,
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

--- opts (optional): on_empty() is called instead of the "no books found"
-- message when the search returns nothing.
function IrcBooks:doSearch(query, opts)
    opts = opts or {}
    pcall(util.makePath, self.work_dir)
    local ok = self.fetcher:search(query, {
        on_status = function(text) self:showStatus(text) end,
        on_progress = function(received, total)
            self:showProgress(_("Receiving search results…"), received, total)
        end,
        on_done = function(list)
            self:closeStatus()
            if #list == 0 and opts.on_empty then
                opts.on_empty()
                return
            end
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
    -- What the results screen shows; changed from its filter dialog.
    self.view = {
        query = query,
        list = list,
        formats = self.settings.formats or "",
        text = "",
    }
    if self.results_menu then UIManager:close(self.results_menu) end
    local menu
    menu = Menu:new{
        title = "",
        item_table = {},
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:showFilterDialog() end,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        multilines_show_more_text = true,
        onMenuSelect = function(_menu, item)
            if item.is_filter then
                self:showFilterDialog()
            else
                self:confirmDownload(item.entry)
            end
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
            if self.results_menu == menu then
                self.results_menu = nil
                self.view = nil
            end
        end,
    }
    self.results_menu = menu
    self:refreshResults()
    UIManager:show(menu)
end

function IrcBooks:closeResults()
    local menu = self.results_menu
    if menu then
        self.results_menu = nil
        self.view = nil
        UIManager:close(menu)
    end
end

function IrcBooks:refreshResults()
    local view, menu = self.view, self.results_menu
    if not view or not menu then return end
    local shown = results.search(results.filter(view.list, view.formats), view.text)
    local summary = {}
    summary[#summary + 1] = view.formats ~= "" and T(_("formats: %1"), view.formats) or _("all formats")
    if view.text ~= "" then summary[#summary + 1] = T(_("matching “%1”"), view.text) end
    local items = {{
        text = T(_("Filter / search results… (%1)"), table.concat(summary, ", ")),
        mandatory = T(_("%1 of %2"), #shown, #view.list),
        is_filter = true,
        bold = true,
    }}
    for i = 1, #shown do
        local entry = shown[i]
        items[#items + 1] = {
            text = entry.title,
            mandatory = entry.size and T("%1 · %2", entry.size, entry.bot) or entry.bot,
            entry = entry,
        }
    end
    local title = T(_("%1 results for “%2”"), #shown, view.query)
    if menu.switchItemTable then
        menu:switchItemTable(title, items, 1)
    end
end

function IrcBooks:showFilterDialog()
    local view = self.view
    if not view then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function apply(formats, text)
        if formats ~= nil then view.formats = formats end
        if text ~= nil then view.text = text end
        UIManager:close(dialog)
        self:refreshResults()
    end
    local buttons = {
        {{
            text = view.text ~= "" and T(_("Search in results: “%1”"), view.text) or _("Search in results…"),
            callback = function()
                UIManager:close(dialog)
                self:showResultSearchInput()
            end,
        }},
        {{
            text = _("All formats") .. (view.formats == "" and "  ✓" or ""),
            callback = function() apply("", nil) end,
        }},
    }
    local row = {}
    for _i, f in ipairs(results.formats(view.list)) do
        local selected = view.formats:lower():gsub("%s", "") == f.ext
        row[#row + 1] = {
            text = T("%1 (%2)", f.ext, f.count) .. (selected and "  ✓" or ""),
            callback = function() apply(f.ext, nil) end,
        }
        if #row == 3 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    buttons[#buttons + 1] = {{
        text = _("Clear filters"),
        callback = function() apply("", "") end,
    }}
    dialog = ButtonDialog:new{
        title = _("Filter results"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function IrcBooks:showResultSearchInput()
    local view = self.view
    local dialog
    dialog = InputDialog:new{
        title = _("Search in results"),
        input = view.text,
        input_hint = _("Words in title or author"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Clear"),
                callback = function()
                    UIManager:close(dialog)
                    view.text = ""
                    self:refreshResults()
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    view.text = trim(dialog:getInputText())
                    self:refreshResults()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
    if self.hardcover:onDownloaded(path) then return end
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
            self:closeResults()
            self:openBook(path)
        end,
    })
end

function IrcBooks:openBook(path)
    if self.ui.document and self.ui.switchDocument then
        self.ui:switchDocument(path)
    else
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end
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
