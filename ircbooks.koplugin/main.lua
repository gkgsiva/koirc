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
local DownloadQueue = require("downloadqueue")
local Hardcover = require("koirc/hardcover")
local DebugLog = require("koirc/debuglog")
local ReadingStats = require("readingstats")
local Cleanup = require("cleanup")
local UiPrefs = require("uiprefs")

local logger = DebugLog.wrap(require("logger"))

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
    preferred_formats = results.DEFAULT_PREFERRED,
    sort = "format",
    max_size_mb = 0,
    hardcover_status_sync = true,
    hardcover_progress_sync = true,
    hardcover_series_follow = true,
    hardcover_metadata = true,
    hardcover_rating_prompt = true,
    hardcover_new_releases = true,
    hardcover_auto_sync = true,
    hide_unsupported = true,
    download_toasts = true,
    list_size = "normal",
    rename_downloads = false,
    organise = "none",
}

local ORGANISE_NAMES = {
    none = _("all in the download folder"),
    author = _("a folder per author"),
    series = _("a folder per series"),
    author_series = _("author, then series folders"),
}
local ORGANISE_MODES = { "none", "author", "series", "author_series" }

-- How many other results to try when a bot does not send a book.
local FALLBACK_TRIES = 2

local HISTORY_MAX = 15

local SORT_NAMES = {
    format = _("preferred format"),
    size_asc = _("size, smallest first"),
    size_desc = _("size, largest first"),
    name = _("name"),
    none = _("as received"),
}

local SIZE_LIMITS = { 0, 2, 5, 10, 20, 50 }

local LIST_SIZE_NAMES = {
    compact = _("compact (more per page)"),
    normal = _("normal"),
    large = _("large (bigger buttons)"),
}

-- One IRC connection and one download queue for the whole KOReader session,
-- shared by the plugin instances of the file browser and the reader, so
-- background downloads keep going when a book is opened or closed.
local Shared = {}

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
    local existing = G_reader_settings:readSetting(SETTINGS_KEY)
    self.settings = existing or {}
    -- People updating from an older version already set things up.
    if existing and self.settings.setup_done == nil and self.settings.nick then self.settings.setup_done = true end
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    if not self.settings.nick or self.settings.nick == "" then
        math.randomseed(os.time())
        self.settings.nick = "koreader" .. math.random(1000, 9999)
        self:saveSettings()
    end
    self.work_dir = DataStorage:getDataDir() .. "/cache/ircbooks"
    Shared.plugin = self
    if not Shared.fetcher then
        Shared.fetcher = Fetcher.new{
            socket = socket,
            ssl = ssl,
            config = function() return Shared.plugin.settings end,
            work_dir = self.work_dir,
            log = function(line) logger.dbg("ircbooks:", line) end, -- also kept for "Save debug log"
        }
        Shared.tick = function() Shared.plugin:onTick() end
    end
    self.fetcher = Shared.fetcher
    self.tick = Shared.tick
    self.hardcover = HardcoverUI.new(self)
    if not Shared.queue then
        Shared.queue = DownloadQueue.new{
            fetcher = function() return Shared.fetcher end,
            start_ticking = function() Shared.plugin:startTicking() end,
            settings = function() return Shared.plugin.settings end,
            download_dir = function() return Shared.plugin:getDownloadDir() end,
            after_download = function(path, book, entry) return Shared.plugin:afterDownload(path, book, entry) end,
            on_book_done = function(book, path) Shared.plugin.hardcover:onQueuedDownload(book, path) end,
            on_change = function() Shared.plugin.hardcover:refreshBooks() end,
        }
    end
    self.queue = Shared.queue
    if not self.ui.document then self.hardcover:maybeOpenAtStart() end
    if not Shared.started then
        Shared.started = true
        UIManager:scheduleIn(20, function()
            local ok, online = pcall(function() return NetworkMgr:isOnline() end)
            if ok and online then Shared.plugin.hardcover:maybeBackgroundSync() end
        end)
    end
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
    Dispatcher:registerAction("ircbooks_stats", {
        category = "none", event = "IrcBooksStats", title = _("IRC book search: reading stats"), general = true,
    })
    Dispatcher:registerAction("ircbooks_cleanup", {
        category = "none", event = "IrcBooksCleanup", title = _("IRC book search: clean up finished books"), general = true,
    })
end

function IrcBooks:onIrcBooksStats()
    ReadingStats.show(self.ui)
    return true
end

function IrcBooks:onIrcBooksCleanup()
    Cleanup.new(self):show()
    return true
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
                text = _("Recent searches…"),
                enabled_func = function() return #(self.settings.search_history or {}) > 0 end,
                callback = function() self:showHistory() end,
            },
            {
                text = _("Hardcover lists…"),
                callback = function() self.hardcover:open() end,
            },
            {
                text = _("This book on Hardcover…"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback = function() self:showOpenBookDialog() end,
            },
            {
                text = _("Reading stats…"),
                callback = function() ReadingStats.show(self.ui) end,
            },
            {
                text = _("Clean up finished books…"),
                callback = function() Cleanup.new(self):show() end,
            },
            {
                text_func = function() return self:queueMenuText() end,
                enabled_func = function() return self.queue:isRunning() or self.queue:isPaused() end,
                callback = function() self:showQueueDialog() end,
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
                    self.queue:stop()
                    self.fetcher:cancel()
                    self.fetcher:disconnect()
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = self:getSettingsMenu(),
            },
            {
                text = _("Save debug log"),
                callback = function() self:saveDebugLog() end,
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
        valueItem("preferred_formats", _("Preferred formats, best first"), results.DEFAULT_PREFERRED,
                  { empty = _("none"), allow_empty = true }),
        {
            text_func = function()
                return T(_("Sort results by: %1"), SORT_NAMES[self.settings.sort] or SORT_NAMES.format)
            end,
            sub_item_table = self:getSortMenu(),
        },
        {
            text_func = function()
                return T(_("Download folder: %1"), self:getDownloadDir())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:chooseDownloadDir(function() touchmenu_instance:updateItems() end)
            end,
            separator = true,
        },
        {
            text = _("Rename downloads to “Author - Title”"),
            checked_func = function() return self.settings.rename_downloads end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.settings.rename_downloads = not self.settings.rename_downloads
                self:saveSettings()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return T(_("Save into: %1"), ORGANISE_NAMES[self.settings.organise] or ORGANISE_NAMES.none)
            end,
            sub_item_table = self:getOrganiseMenu(),
            separator = true,
        },
        self.hardcover:getSettingsItem(),
        self.hardcover:getStartupItem(),
        self.hardcover:getStatusSyncItem(),
        self.hardcover:getToggleItem("hardcover_progress_sync", _("Send reading progress to Hardcover")),
        self.hardcover:getToggleItem("hardcover_series_follow", _("Offer the next book in a series")),
        self.hardcover:getToggleItem("hardcover_metadata", _("Add Hardcover title, author, series and cover to downloads")),
        self.hardcover:getToggleItem("hardcover_rating_prompt", _("Ask for a rating when I finish a book")),
        self.hardcover:getToggleItem("hardcover_new_releases", _("Look for new releases when syncing")),
        self.hardcover:getToggleItem("hardcover_auto_sync", _("Sync with Hardcover in the background when Wi-Fi comes on")),
        {
            text_func = function()
                return T(_("List size: %1"), LIST_SIZE_NAMES[self.settings.list_size] or LIST_SIZE_NAMES.normal)
            end,
            sub_item_table = self:getListSizeMenu(),
            separator = true,
        },
        self.hardcover:getToggleItem("hide_unsupported", _("Hide formats this device can't open")),
        self.hardcover:getToggleItem("download_toasts", _("Show a notice when each background download finishes")),
        {
            text = _("Test connection"),
            callback = function() self:testConnection() end,
        },
        {
            text = _("Run setup again…"),
            callback = function() self:showSetupWizard() end,
        },
        {
            text = _("Save debug log"),
            callback = function() self:saveDebugLog() end,
        },
    }
end

function IrcBooks:getListSizeMenu()
    local items = {}
    for i, size in ipairs(UiPrefs.SIZES) do
        items[i] = {
            text = LIST_SIZE_NAMES[size],
            radio = true,
            checked_func = function() return (self.settings.list_size or "normal") == size end,
            callback = function()
                self.settings.list_size = size
                self:saveSettings()
            end,
        }
    end
    return items
end

function IrcBooks:getOrganiseMenu()
    local items = {}
    for i, mode in ipairs(ORGANISE_MODES) do
        items[i] = {
            text = ORGANISE_NAMES[mode],
            radio = true,
            checked_func = function() return (self.settings.organise or "none") == mode end,
            callback = function()
                self.settings.organise = mode
                self:saveSettings()
            end,
        }
    end
    return items
end

function IrcBooks:getSortMenu()
    local items = {}
    for i, mode in ipairs(results.SORTS) do
        items[i] = {
            text = SORT_NAMES[mode],
            radio = true,
            checked_func = function() return (self.settings.sort or "format") == mode end,
            callback = function()
                self.settings.sort = mode
                self:saveSettings()
            end,
        }
    end
    return items
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
        self.fetcher:cancel()
        self.fetcher:disconnect()
        self:closeStatus()
        if self.queue:isRunning() then
            -- Its job was dropped; move on to the next book.
            self.queue:skipCurrent(tostring(delay))
            return
        end
        -- Also when no job is left: the error may come from showing its result.
        UIManager:show(InfoMessage:new{ text = T(_("Something went wrong:\n%1"), tostring(delay)) })
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

function IrcBooks:showProgress(label, received, total, found)
    if found and found > 0 then label = T(_("%1\n%2 results so far"), label, found) end
    -- Avoid refreshing the e-ink screen for every chunk.
    local now = socket.gettime()
    if self.status_widget and self.progress_time and now - self.progress_time < 3 then return end
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
    -- "fast": a quick e-ink update for a message that comes and goes.
    if widget then UIManager:close(widget, "fast") end
end

function IrcBooks:showError(text)
    self:closeStatus()
    UIManager:show(InfoMessage:new{ text = text })
end

-------------------------------------------------------------------------------
-- First-run setup and connection test
-------------------------------------------------------------------------------

--- A short guided setup: network, nickname, a connection test and
-- (optionally) the Hardcover API key. on_done runs when it is finished or
-- skipped.
function IrcBooks:showSetupWizard(on_done)
    local ButtonDialog = require("ui/widget/buttondialog")
    local function finish()
        self.settings.setup_done = true
        self:saveSettings()
        if on_done then on_done() end
    end
    local step3
    local function step2()
        local dialog
        dialog = InputDialog:new{
            title = _("Step 2 of 3: your nickname"),
            description = _("The name other people in the channel see. Any name works; the plugin adds numbers if it is taken."),
            input = self.settings.nick or "",
            buttons = {{
                { text = _("Skip setup"), id = "close", callback = function() UIManager:close(dialog) finish() end },
                { text = _("Next"), is_enter_default = true, callback = function()
                    local nick = trim(dialog:getInputText()):gsub("[^%w%-_%[%]{}\\|^`]", "")
                    UIManager:close(dialog)
                    if nick ~= "" and nick ~= self.settings.nick then
                        self.settings.nick = nick:sub(1, 16)
                        self:saveSettings()
                        self:reconnectLater()
                    end
                    step3()
                end },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
    step3 = function(result)
        local dialog
        local text = _("Step 3 of 3: test the connection")
        text = text .. "\n\n" .. T(_("Server: %1\nChannel: %2\nNickname: %3"), self.settings.host, self.settings.channel, self.settings.nick)
        if result then text = text .. "\n\n" .. result end
        local buttons = {
            {{ text = _("Test connection"), callback = function()
                UIManager:close(dialog)
                self:testConnection(function(res) step3(res) end)
            end }},
            {{ text = self.hardcover:hasToken() and _("Hardcover API key ✓") or _("Add Hardcover API key (optional)…"),
               callback = function()
                UIManager:close(dialog)
                self.hardcover:showTokenDialog(function() step3(result) end)
            end }},
            {{ text = _("Finish"), callback = function()
                UIManager:close(dialog)
                finish()
            end }},
        }
        dialog = ButtonDialog:new{ title = text, title_align = "left", buttons = buttons }
        UIManager:show(dialog)
    end
    local dialog
    local buttons = {}
    for _i, p in ipairs(PRESETS) do
        local current = self.settings.host == p.host and self.settings.channel == p.channel
        buttons[#buttons + 1] = {{
            text = p.name .. (current and "  ✓" or ""),
            callback = function()
                UIManager:close(dialog)
                self.settings.host = p.host
                self.settings.channel = p.channel
                self.settings.search_cmd = p.search_cmd
                self.settings.port = self.settings.tls and 6697 or 6667
                self:saveSettings()
                self:reconnectLater()
                step2()
            end,
        }}
    end
    buttons[#buttons + 1] = {
        { text = _("Skip setup"), callback = function() UIManager:close(dialog) finish() end },
    }
    dialog = ButtonDialog:new{
        title = _("Welcome to IRC book search.\n\nStep 1 of 3: pick a network. IRCHighway #ebooks has the most books; you can change this later in Settings."),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Connect and join the channel, without blocking the screen, and report.
-- after(result_text) (optional) gets the result instead of a message.
function IrcBooks:testConnection(after)
    local f = self.fetcher
    if f:isBusy() or self.queue:isRunning() then
        UIManager:show(InfoMessage:new{ text = _("A search or download is running. Try again when it is done.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        f:disconnect("test")
        f.last_error = nil
        f:connect()
        self:startTicking()
        local started = socket.gettime()
        local msg = InfoMessage:new{ text = T(_("Testing connection to %1…"), self.settings.host) }
        UIManager:show(msg)
        local function report(text)
            UIManager:close(msg, "fast")
            if after then after(text) else UIManager:show(InfoMessage:new{ text = text }) end
        end
        local function check()
            if f.irc_state == "ready" then
                report(T(_("✓ Connected to %1 and joined %2 as %3."), self.settings.host, self.settings.channel, f.nick or self.settings.nick))
            elseif not f.conn or socket.gettime() - started > 95 then
                if f.conn then f:disconnect("test") end
                report(T(_("✗ Could not connect to %1:\n%2"), self.settings.host, f.last_error or _("no answer")))
            else
                UIManager:scheduleIn(0.5, check)
            end
        end
        UIManager:scheduleIn(0.5, check)
    end)
end

--- Start connecting while the user types a search, so it goes out sooner.
function IrcBooks:preconnect()
    local f = self.fetcher
    if f.conn or f:isBusy() or self.queue:isRunning() then return end
    local ok, online = pcall(function()
        if NetworkMgr.isOnline then return NetworkMgr:isOnline() end
        return NetworkMgr:isConnected()
    end)
    if ok and online then
        f:connect()
        self:startTicking()
    end
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------

function IrcBooks:showSearchDialog()
    if not self.settings.setup_done then
        self:showSetupWizard(function() self:showSearchDialog() end)
        return
    end
    self.hardcover:clearCurrent()
    self:preconnect()
    local dialog
    dialog = InputDialog:new{
        title = _("Search IRC for books"),
        input = self.last_query or "",
        input_hint = _("Author and/or title"),
        description = T(_("Searching %1 on %2"), self.settings.channel, self.settings.host),
        buttons = {{
            {
                text = _("Recent searches"),
                enabled = #(self.settings.search_history or {}) > 0,
                callback = function()
                    UIManager:close(dialog)
                    self:showHistory()
                end,
            },
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
    if self.queue:isRunning() then
        self:showQueueBusy()
        return
    end
    pcall(util.makePath, self.work_dir)
    self:addToHistory(query)
    local ok = self.fetcher:search(query, {
        on_status = function(text) self:showStatus(text) end,
        on_progress = function(received, total, found)
            self:showProgress(_("Receiving search results…"), received, total, found)
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

--- Can this KOReader open files of this format?
local function canOpen(ext)
    local ok, res = pcall(function()
        return require("document/documentregistry"):hasProvider("x." .. ext)
    end)
    if not ok then return true end
    return res and true or false
end

function IrcBooks:showResults(query, list)
    if #list == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("No books found for “%1”."), query) })
        return
    end
    -- What the results screen shows; changed from its filter dialog. The
    -- format and bot picked there are remembered for the next search.
    self.view = {
        query = query,
        list = list,
        formats = self.settings.result_formats or self.settings.formats or "",
        bot = self.settings.result_bot or "",
        text = "",
        sort = self.settings.sort or "format",
        max_mb = tonumber(self.settings.max_size_mb) or 0,
        -- The Hardcover book being searched for, to highlight its best match.
        book = self.hardcover:currentBook(),
        selected = nil, -- set of entries while choosing several
    }
    if self.results_menu then UIManager:close(self.results_menu) end
    local menu
    menu = Menu:new(UiPrefs.apply(self.settings, {
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
        onMenuSelect = function(_menu, item) self:onResultSelected(item) return true end,
        onMenuHold = function(_menu, item)
            if item.entry then self:showResultActions(item.entry) else self:onResultSelected(item) end
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
            if self.results_menu == menu then
                self.results_menu = nil
                self.view = nil
            end
        end,
    }))
    self.results_menu = menu
    self:refreshResults()
    UIManager:show(menu)
end

function IrcBooks:onResultSelected(item)
    local view = self.view
    if not view then return end
    if item.is_filter then
        self:showFilterDialog()
    elseif item.start_select then
        view.selected = {}
        self:refreshResults(true)
    elseif item.cancel_select then
        view.selected = nil
        self:refreshResults(true)
    elseif item.download_selected then
        self:downloadSelected()
    elseif item.entry then
        if view.selected then
            view.selected[item.entry] = not view.selected[item.entry] or nil
            self:refreshResults(true)
        else
            self:confirmDownload(item.entry)
        end
    end
end

--- The filtered and sorted results, the best match, and how many results
-- were hidden for being in a format the device can't open.
function IrcBooks:shownResults()
    local view = self.view
    local prefs = results.parseFormats(self.settings.preferred_formats)
    local base = view.list
    local hidden = 0
    if self.settings.hide_unsupported ~= false then
        local kept, n = results.filterOpenable(base, canOpen)
        -- Never hide everything: then show what there is.
        if #kept > 0 then base, hidden = kept, n end
    end
    local shown = results.search(results.filterBot(results.filter(base, view.formats), view.bot), view.text)
    shown = results.filterSize(shown, view.max_mb * 1048576)
    shown = results.sort(shown, view.sort, prefs)
    -- Put the result that best matches the Hardcover book first.
    local best
    if view.book then
        best = Hardcover.rankResults(view.book, shown, function(e) return results.formatRank(e, prefs) end)[1]
        if best then
            for i = 1, #shown do
                if shown[i] == best then table.remove(shown, i) break end
            end
            table.insert(shown, 1, best)
        end
    end
    return shown, best, hidden
end

function IrcBooks:refreshResults(keep_page)
    local view, menu = self.view, self.results_menu
    if not view or not menu then return end
    local shown, best, hidden = self:shownResults()
    -- A remembered format or bot that this search doesn't have would hide
    -- everything: drop it for this search.
    if #shown == 0 and (view.formats ~= "" or view.bot ~= "") and view.text == "" and not view.reset_once then
        view.reset_once = true
        view.formats, view.bot = "", ""
        shown, best, hidden = self:shownResults()
    end
    local summary = {}
    summary[#summary + 1] = view.formats ~= "" and T(_("formats: %1"), view.formats) or _("all formats")
    if view.bot ~= "" then summary[#summary + 1] = T(_("bot: %1"), view.bot) end
    if view.max_mb > 0 then summary[#summary + 1] = T(_("up to %1 MB"), view.max_mb) end
    summary[#summary + 1] = T(_("sorted by %1"), SORT_NAMES[view.sort] or view.sort)
    if view.text ~= "" then summary[#summary + 1] = T(_("matching “%1”"), view.text) end
    if hidden > 0 then summary[#summary + 1] = T(_("%1 hidden (can't open)"), hidden) end
    local items = {{
        text = T(_("Filter / search results… (%1)"), table.concat(summary, ", ")),
        mandatory = T(_("%1 of %2"), #shown, #view.list),
        is_filter = true,
        bold = true,
    }}
    local sel = view.selected
    if sel then
        local n = 0
        for _e in pairs(sel) do n = n + 1 end
        items[#items + 1] = {
            text = n > 0 and T(_("Download %1 selected in the background"), n) or _("Tap books to select them"),
            download_selected = n > 0 or nil,
            bold = true,
        }
        items[#items + 1] = { text = _("Cancel selection"), cancel_select = true, separator = true }
    else
        items[#items + 1] = {
            text = _("Select several to download…"),
            mandatory = _("hold a book for more"),
            start_select = true,
            separator = true,
        }
    end
    for i = 1, #shown do
        local entry = shown[i]
        local mark = ""
        if sel then mark = sel[entry] and "☑ " or "☐ " end
        if entry == best then mark = mark .. "★ " end
        local badge = results.badge(entry)
        items[#items + 1] = {
            text = mark .. entry.title,
            mandatory = badge ~= "" and T("%1 · %2", badge, entry.bot) or entry.bot,
            bold = entry == best or nil,
            entry = entry,
        }
    end
    local title = T(_("%1 results for “%2”"), #shown, view.query)
    if menu.switchItemTable then
        -- No item number: with items_max_lines, KOReader looks the page up
        -- before it lays out the new items and fails on the empty first list.
        local page = keep_page and menu.page
        menu:switchItemTable(title, items)
        -- Stay on the same page while picking books.
        if page and page > 1 and menu.page_num and page <= menu.page_num and menu.onGotoPage then
            pcall(menu.onGotoPage, menu, page)
        end
    end
end

--- Hold a result: download it, or search for more by its author or series.
function IrcBooks:showResultActions(entry)
    local ButtonDialog = require("ui/widget/buttondialog")
    local p = results.parts(entry)
    local dialog
    local function search(q)
        UIManager:close(dialog)
        self.last_query = q
        NetworkMgr:runWhenOnline(function() self:doSearch(q) end)
    end
    local buttons = {}
    if p.author then
        buttons[#buttons + 1] = {{ text = T(_("More by %1"), p.author), callback = function() search(p.author) end }}
    end
    if p.series then
        local q = p.author and (p.author .. " " .. p.series) or p.series
        buttons[#buttons + 1] = {{ text = T(_("Series: %1"), p.series), callback = function() search(q) end }}
    end
    if p.series and p.series_num then
        buttons[#buttons + 1] = {{
            text = T(_("Next in series (%1)"), p.series_num + 1),
            callback = function() search(results.nextInSeriesQuery(p)) end,
        }}
    end
    buttons[#buttons + 1] = {
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
        { text = _("Download"), callback = function()
            UIManager:close(dialog)
            self:confirmDownload(entry)
        end },
    }
    dialog = ButtonDialog:new{
        title = T(_("%1\n\n%2 · from %3"), entry.title, results.badge(entry), entry.bot),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Queue the selected results (exact files, no new search) in the background.
function IrcBooks:downloadSelected()
    local view = self.view
    if not view or not view.selected then return end
    local books = {}
    for _i, e in ipairs(view.list) do
        if view.selected[e] then
            local p = results.parts(e)
            books[#books + 1] = { title = p.title or e.title, author = p.author, entry = e }
        end
    end
    if #books == 0 then return end
    if self.queue:isRunning() then
        self:showQueueBusy()
        return
    end
    view.selected = nil
    self:refreshResults(true)
    local name = view.query
    NetworkMgr:runWhenOnline(function() self.queue:start(books, name) end)
end

function IrcBooks:showFilterDialog()
    local view = self.view
    if not view then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function apply(formats, text, sort, max_mb, bot)
        if bot ~= nil then
            view.bot = bot
            self.settings.result_bot = bot
            self:saveSettings()
        end
        if formats ~= nil then
            view.formats = formats
            self.settings.result_formats = formats
            self:saveSettings()
        end
        if text ~= nil then view.text = text end
        if sort ~= nil then
            view.sort = sort
            -- Remember the choice for the next search.
            self.settings.sort = sort
            self:saveSettings()
        end
        if max_mb ~= nil then
            view.max_mb = max_mb
            self.settings.max_size_mb = max_mb
            self:saveSettings()
        end
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
    -- Bots (most results first)
    row = {{
        text = _("All bots") .. (view.bot == "" and "  ✓" or ""),
        callback = function() apply(nil, nil, nil, nil, "") end,
    }}
    for i, b in ipairs(results.bots(view.list)) do
        if i > 5 then break end
        row[#row + 1] = {
            text = T("%1 (%2)", b.bot, b.count) .. (view.bot:lower() == b.bot:lower() and "  ✓" or ""),
            callback = function() apply(nil, nil, nil, nil, b.bot) end,
        }
        if #row == 3 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    -- Sorting
    row = {}
    for _i, mode in ipairs({ "format", "size_asc", "size_desc", "name" }) do
        local label = ({ format = _("Format"), size_asc = _("Smallest"), size_desc = _("Largest"), name = _("Name") })[mode]
        row[#row + 1] = {
            text = label .. (view.sort == mode and "  ✓" or ""),
            callback = function() apply(nil, nil, mode) end,
        }
    end
    buttons[#buttons + 1] = row
    -- Maximum size
    row = {}
    for _i, mb in ipairs(SIZE_LIMITS) do
        row[#row + 1] = {
            text = (mb == 0 and _("Any size") or T(_("≤ %1 MB"), mb)) .. (view.max_mb == mb and " ✓" or ""),
            callback = function() apply(nil, nil, nil, mb) end,
        }
        if #row == 3 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    buttons[#buttons + 1] = {{
        text = _("Clear filters"),
        callback = function() apply("", "", nil, 0, "") end,
    }}
    dialog = ButtonDialog:new{
        title = _("Filter and sort results"),
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

function IrcBooks:chooseDownloadDir(on_done)
    require("folderpicker").choose(self:getDownloadDir(), function(path)
        self:setDownloadDir(path)
        if on_done then on_done(path) end
    end)
end

function IrcBooks:setDownloadDir(path)
    self.settings.download_dir = path
    self:saveSettings()
end

function IrcBooks:confirmDownload(entry)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dir = self:getDownloadDir()
    local text = T(_("Download this book?\n\n%1\n\nSize: %2\nFrom: %3\nSave to: %4"),
                   entry.title, entry.size or _("unknown"), entry.bot, dir)
    if entry.ext == "rar" or entry.ext == "7z" then
        text = text .. "\n\n" .. _("Note: this is an archive that KOReader cannot open by itself.")
    end
    local existing = self.hardcover:findExisting(entry)
    if existing then
        text = text .. "\n\n" .. T(_("⚠ You may already have this book:\n%1"), existing)
    end
    local dialog
    dialog = ButtonDialog:new{
        title = text,
        title_align = "left",
        buttons = {
            {
                {
                    text = _("Change save folder…"),
                    callback = function()
                        UIManager:close(dialog)
                        self:chooseDownloadDir(function() self:confirmDownload(entry) end)
                    end,
                },
                {
                    text = _("New folder…"),
                    callback = function()
                        UIManager:close(dialog)
                        require("folderpicker").promptNewFolder(dir, function(path)
                            self:setDownloadDir(path)
                            self:confirmDownload(entry)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Download"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.queue:isRunning() then
                            self:showQueueBusy()
                            return
                        end
                        NetworkMgr:runWhenOnline(function() self:doDownload(entry, dir) end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--- Other results that look like the same book as entry, best first, for
-- when a bot does not send it.
function IrcBooks:fallbacks(entry, tried)
    local view = self.view
    if not view or not view.list then return {} end
    local book = self.hardcover:currentBook() or Hardcover.entryBook(entry)
    local prefs = results.parseFormats(self.settings.preferred_formats)
    local out = {}
    for _i, e in ipairs(Hardcover.rankResults(book, results.filter(view.list, view.formats),
                                              function(x) return results.formatRank(x, prefs) end)) do
        if not tried[e.request] and not results.ARCHIVES[results.bookExt(e) or ""] then out[#out + 1] = e end
    end
    return out
end

function IrcBooks:doDownload(entry, dir, tried)
    tried = tried or {}
    tried[entry.request] = true
    local attempts = 0
    for _k in pairs(tried) do attempts = attempts + 1 end
    local ok = self.fetcher:download(entry, dir, {
        on_status = function(text) self:showStatus(text) end,
        on_progress = function(received, total)
            self:showProgress(T(_("Downloading %1"), entry.title), received, total)
        end,
        on_done = function(path)
            self:closeStatus()
            local book = self.hardcover:currentBook()
            local new_path = self:afterDownload(path, book, entry)
            self:onDownloaded(new_path or path, entry)
        end,
        on_error = function(err)
            local alt = attempts <= FALLBACK_TRIES and self:fallbacks(entry, tried)[1]
            if alt then
                logger.warn("ircbooks: download failed, trying another bot:", err)
                self:showStatus(T(_("%1 did not send the book (%2).\nTrying %3…"), entry.bot, err, alt.bot))
                UIManager:scheduleIn(2, function() self:doDownload(alt, dir, tried) end)
            else
                self:showError(err)
            end
        end,
    })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Another request is still running.") })
        return
    end
    self:startTicking()
end

function IrcBooks:onDownloaded(path, entry)
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
    if self.hardcover:onDownloaded(path) then return end
    self:showDownloadedDialog(path, entry)
end

--- After a download: quick buttons to open the book, add it to Hardcover,
-- or look for the next book in its series.
function IrcBooks:showDownloadedDialog(path, entry)
    local ButtonDialog = require("ui/widget/buttondialog")
    local DocumentRegistry = require("document/documentregistry")
    local can_open = DocumentRegistry:hasProvider(path)
    local p = entry and results.parts(entry) or {}
    local dialog
    local function button(text, fn)
        return { text = text, callback = function() UIManager:close(dialog) fn() end }
    end
    local buttons = {}
    local row = {}
    if can_open then
        row[#row + 1] = button(_("Open"), function()
            self:closeResults()
            self:openBook(path)
        end)
    end
    if self.hardcover.json and self.hardcover:hasToken() then
        row[#row + 1] = button(_("Add to Hardcover…"), function()
            self.hardcover:addToHardcover({ title = p.title or (entry and entry.title), author = p.author }, path)
        end)
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    if p.series and p.series_num then
        buttons[#buttons + 1] = { button(T(_("Next in series: %1 #%2"), p.series, p.series_num + 1), function()
            local q = results.nextInSeriesQuery(p)
            self.last_query = q
            NetworkMgr:runWhenOnline(function() self:doSearch(q) end)
        end) }
    end
    buttons[#buttons + 1] = { button(_("Close"), function() end) }
    local text = T(_("Saved to:\n%1"), path)
    if not can_open then text = text .. "\n\n" .. _("KOReader can't open this format.") end
    dialog = ButtonDialog:new{
        title = text,
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
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
-- Search history
-------------------------------------------------------------------------------

function IrcBooks:addToHistory(query)
    local h = self.settings.search_history or {}
    for i = #h, 1, -1 do
        if h[i]:lower() == query:lower() then table.remove(h, i) end
    end
    table.insert(h, 1, query)
    while #h > HISTORY_MAX do table.remove(h) end
    self.settings.search_history = h
    self:saveSettings()
end

--- Recent searches: tap one to search again, hold it to edit it first.
function IrcBooks:showHistory()
    local h = self.settings.search_history or {}
    if #h == 0 then
        UIManager:show(InfoMessage:new{ text = _("No recent searches yet.") })
        return
    end
    local items = {}
    for i, q in ipairs(h) do items[i] = { text = q, query = q } end
    items[#items].separator = true
    items[#items + 1] = { text = _("Clear recent searches"), clear = true }
    local menu
    menu = Menu:new{
        title = _("Recent searches"),
        subtitle = _("Tap to search again, hold to edit"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_menu, item)
            UIManager:close(menu)
            if item.clear then
                self.settings.search_history = {}
                self:saveSettings()
                UIManager:show(InfoMessage:new{ text = _("Recent searches cleared."), timeout = 2 })
            elseif item.query then
                self.hardcover:clearCurrent()
                self.last_query = item.query
                NetworkMgr:runWhenOnline(function() self:doSearch(item.query) end)
            end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item.query then
                UIManager:close(menu)
                self.last_query = item.query
                self:showSearchDialog()
            end
            return true
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-------------------------------------------------------------------------------
-- Background downloads
-------------------------------------------------------------------------------

function IrcBooks:queueMenuText()
    local q = self.queue
    if q:isRunning() then
        return T(_("Background downloads: %1 (tap to stop)"), q:statusText())
    elseif q:isPaused() then
        return T(_("Background downloads paused: %1 left"), q:remaining())
    end
    return _("No background downloads")
end

function IrcBooks:showQueueBusy()
    UIManager:show(ConfirmBox:new{
        text = T(_("Background downloads are running (%1).\n\nStop them to search yourself?"), self.queue:statusText()),
        ok_text = _("Stop"),
        cancel_text = _("Keep going"),
        ok_callback = function() self.queue:stop() end,
    })
end

function IrcBooks:showQueueDialog()
    local q = self.queue
    if q:isRunning() then
        UIManager:show(ConfirmBox:new{
            text = T(_("Downloading in the background:\n%1\n\n%2 books left."), q:statusText(), q:remaining()),
            ok_text = _("Stop"),
            cancel_text = _("Keep going"),
            ok_callback = function() q:stop() end,
        })
    elseif q:isPaused() then
        self:askResumeQueue()
    end
end

function IrcBooks:askResumeQueue()
    local q = self.queue
    if not q:isPaused() or self.resume_asked then return end
    self.resume_asked = true
    UIManager:show(ConfirmBox:new{
        text = T(_("Background downloads were paused. %1 books are left.\n\nContinue?"), q:remaining()),
        ok_text = _("Continue"),
        cancel_text = _("Stop"),
        ok_callback = function()
            self.resume_asked = nil
            NetworkMgr:runWhenOnline(function() q:resume() end)
        end,
        cancel_callback = function()
            self.resume_asked = nil
            q:stop()
        end,
    })
end

-------------------------------------------------------------------------------
-- Reading status on Hardcover
-------------------------------------------------------------------------------

function IrcBooks:docProps()
    local props
    pcall(function()
        props = self.ui.doc_props or (self.ui.document and self.ui.document:getProps())
    end)
    return props
end

function IrcBooks:onReaderReady()
    if not self.ui.document then return end
    local file = self.ui.document.file
    -- Let the book finish opening first.
    UIManager:scheduleIn(2, function()
        if self.ui.document and self.ui.document.file == file then
            self.hardcover:onBookOpened(file, self:docProps())
        end
    end)
end

function IrcBooks:onEndOfBook()
    if not self.ui.document then return end
    local file = self.ui.document.file
    UIManager:scheduleIn(1, function() self.hardcover:onBookFinished(file) end)
end

function IrcBooks:onCloseDocument()
    if not self.ui.document or not self.ui.doc_settings then return end
    local file = self.ui.document.file
    local finished = false
    pcall(function()
        local summary = self.ui.doc_settings:readSetting("summary")
        local pct = self.ui.doc_settings:readSetting("percent_finished")
        finished = (type(summary) == "table" and summary.status == "complete") or (tonumber(pct) or 0) >= 0.995
    end)
    if finished then
        UIManager:scheduleIn(1, function() Shared.plugin.hardcover:onBookFinished(file) end)
    else
        self:sendProgress()
    end
end

--- Send the reading position to Hardcover (on close), or only note it to
-- send later (no_send: the device is going to sleep, and a request now would
-- run, and block, right after it wakes up, often before Wi-Fi is back).
function IrcBooks:sendProgress(no_send)
    if not self.ui.document or not self.ui.doc_settings then return end
    local file = self.ui.document.file
    local pct
    pcall(function()
        pct = self.ui.doc_settings:readSetting("percent_finished")
        if self.ui.paging and self.ui.paging.getLastPercent then pct = self.ui.paging:getLastPercent() or pct
        elseif self.ui.rolling and self.ui.rolling.getLastPercent then pct = self.ui.rolling:getLastPercent() or pct end
    end)
    pct = tonumber(pct)
    if not pct then return end
    if no_send then
        pcall(function() Shared.plugin.hardcover:onProgress(file, pct, true) end)
        return
    end
    UIManager:scheduleIn(1, function() Shared.plugin.hardcover:onProgress(file, pct) end)
end

--- Shelf and rating for the open book.
function IrcBooks:showOpenBookDialog()
    if not self.ui.document then return end
    self.hardcover:withBookForFile(self.ui.document.file, self:docProps(), function(book)
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = book.title,
            title_align = "left",
            buttons = {
                { { text = _("Move to shelf…"), callback = function()
                      UIManager:close(dialog)
                      self.hardcover:showShelfPicker(book)
                  end },
                  { text = _("Rate and review…"), callback = function()
                      UIManager:close(dialog)
                      self.hardcover:showRatingDialog(book)
                  end } },
                { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
            },
        }
        UIManager:show(dialog)
    end)
end

-------------------------------------------------------------------------------
-- Debug log
-------------------------------------------------------------------------------

function IrcBooks:saveDebugLog()
    local header = {}
    pcall(function()
        local meta = dofile(self.path .. "/_meta.lua")
        header[#header + 1] = "Plugin version: " .. tostring(meta.version)
    end)
    pcall(function()
        header[#header + 1] = "KOReader: " .. tostring(require("version"):getCurrentRevision())
    end)
    pcall(function()
        header[#header + 1] = "Device: " .. tostring(Device.model or "?")
    end)
    pcall(function()
        header[#header + 1] = "IRC: " .. (self.fetcher:isConnected() and ("connected to " .. tostring(self.settings.host)) or "not connected")
        header[#header + 1] = "Background downloads: " .. self:queueMenuText()
    end)
    local text = DebugLog.report{
        header = header,
        settings = self.settings,
        crash_log = DataStorage:getDataDir() .. "/crash.log",
    }
    local path = self:getDownloadDir() .. "/ircbooks-log-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
    local f, err = io.open(path, "wb")
    if not f then
        self:showError(T(_("Could not save the log:\n%1"), tostring(err)))
        return
    end
    f:write(text)
    f:close()
    UIManager:show(InfoMessage:new{
        text = T(_("Saved the debug log to:\n%1\n\nPasswords and the Hardcover API key are left out."), path),
    })
end

-------------------------------------------------------------------------------
-- After a download: rename, organise, metadata
-------------------------------------------------------------------------------

local function cleanName(s)
    s = tostring(s or ""):gsub("[%c/\\:%*%?\"<>|]", " "):gsub("%s+", " ")
    s = s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if #s > 80 then s = s:sub(1, 80):gsub("[\192-\255][\128-\191]*$", ""):gsub("%s+$", "") end
    return s
end

--- Rename and move a downloaded file as set in Settings, then add the
-- Hardcover metadata and cover. book: the Hardcover book or nil. Returns the
-- file's final path.
function IrcBooks:afterDownload(path, book, entry)
    local new_path = path
    pcall(function() new_path = self:organise(path, book, entry) or path end)
    -- A new book file: look at the folders again next time.
    pcall(function() self.hardcover:forgetFiles() end)
    if book and self.settings.hardcover_metadata ~= false then
        pcall(function() self.hardcover:applyMetadata(new_path, book) end)
    end
    return new_path
end

function IrcBooks:organise(path, book, entry)
    local mode = self.settings.organise or "none"
    if not self.settings.rename_downloads and mode == "none" then return path end
    local dir, name = path:match("^(.*)/([^/]+)$")
    if not dir then return path end
    local ext = name:match("%.([%w]+)$") or "epub"
    local info = book or (entry and Hardcover.entryBook(entry)) or {}
    local author = cleanName(info.author)
    local series = cleanName(info.series_name)
    if series == "" and info.series then series = cleanName((info.series:gsub("%s*#.*$", ""))) end
    local folder = dir
    if (mode == "author" or mode == "author_series") and author ~= "" then folder = folder .. "/" .. author end
    if (mode == "series" or mode == "author_series") and series ~= "" then folder = folder .. "/" .. series end
    local base = name:gsub("%.[%w]+$", "")
    if self.settings.rename_downloads and info.title then
        local pos = tonumber(info.series_pos)
        local parts = {}
        if author ~= "" then parts[#parts + 1] = author end
        if series ~= "" and pos and mode ~= "none" then
            parts[#parts + 1] = string.format(pos == math.floor(pos) and "%02d" or "%04.1f", pos)
        end
        parts[#parts + 1] = cleanName(info.title)
        base = table.concat(parts, " - ")
    end
    local target = folder .. "/" .. base .. "." .. ext
    if target == path then return path end
    if folder ~= dir then util.makePath(folder) end
    local n = 2
    while lfs.attributes(target, "mode") do
        target = string.format("%s/%s (%d).%s", folder, base, n, ext)
        n = n + 1
    end
    local ok, err = os.rename(path, target)
    if not ok then
        logger.warn("ircbooks: could not rename download:", err)
        return path
    end
    return target
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function IrcBooks:stopAll()
    UIManager:unschedule(self.tick)
    self.queue:pause()
    self.fetcher:cancel()
    self.fetcher:disconnect("bye")
    self:closeStatus()
end

function IrcBooks:onSuspend()
    if self.ui.document then self:sendProgress(true) end
    self:stopAll()
end

function IrcBooks:onResume()
    if self.queue:isPaused() and Shared.plugin == self then
        UIManager:scheduleIn(1, function() self:askResumeQueue() end)
    end
end

function IrcBooks:onNetworkConnected()
    if Shared.plugin == self then
        UIManager:scheduleIn(2, function()
            self.hardcover:flushStatus(true)
            self:askResumeQueue()
            -- Refresh saved Hardcover lists without making anyone wait.
            self.hardcover:maybeBackgroundSync()
        end)
    end
end

function IrcBooks:onNetworkDisconnected()
    if self.fetcher.conn then self:stopAll() end
end

function IrcBooks:onCloseWidget()
    -- Opening or closing a book closes this instance and starts another; keep
    -- background downloads going across that switch.
    if self.queue:isRunning() then
        self:closeStatus()
        return
    end
    self:stopAll()
end

return IrcBooks
