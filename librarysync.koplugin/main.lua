local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local sync = require("librarysync/sync")
local util = require("librarysync/util")

-- The running background sync. Module-level, so it survives the switch between the file
-- browser's and the reader's plugin instances.
local Job = require("librarysync/shared")

local LibrarySync = WidgetContainer:extend{
    name = "librarysync",
    is_doc_only = false,
}

local function defaultBase()
    -- Kindle: top-level "Library" folder on the user store.
    if lfs.attributes("/mnt/us", "mode") == "directory" then return "/mnt/us/Library" end
    local home = G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()
    return home .. "/Library"
end

function LibrarySync:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/librarysync.lua")
    self.state_path = DataStorage:getSettingsDir() .. "/librarysync_state.lua"
    Dispatcher:registerAction("librarysync_now", {
        category = "none", event = "LibrarySyncNow", title = _("Library sync: sync now"), general = true,
    })
    Dispatcher:registerAction("librarysync_browse", {
        category = "none", event = "LibraryBrowse", title = _("Library: browse"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    -- Automatic sync: check soon after start, then every hour (and on Wi-Fi / resume events).
    self.auto_timer = function()
        self:autoCheck()
        UIManager:scheduleIn(3600, self.auto_timer)
    end
    UIManager:scheduleIn(15, self.auto_timer)
    -- Once per KOReader launch, open the catalog over the file manager.
    if self.ui.file_chooser and self:get("open_on_start", false) and not LibrarySync.started then
        LibrarySync.started = true
        UIManager:scheduleIn(1, function()
            if self:get("server", "") ~= "" then self:browse() end
        end)
    end
end

function LibrarySync:onLibrarySyncNow() self:syncNow() return true end

function LibrarySync:onCloseWidget()
    if self.auto_timer then UIManager:unschedule(self.auto_timer) end
end

local AUTO_LABELS = { off = _("off"), wifi = _("when Wi-Fi connects"), daily = _("once a day") }
local AUTO_NEXT = { off = "wifi", wifi = "daily", daily = "off" }
local MIN_FREE = { 50, 100, 250, 500, 1000 }

local function wifiOn()
    local ok, on = pcall(function() return NetworkMgr:isConnected() end)
    return ok and on
end

--- Start an automatic sync when it is due. Never turns Wi-Fi on by itself.
--  "wifi": a quick sync each time Wi-Fi connects (at most once an hour).
--  "daily": a full sync when Wi-Fi is on and the last sync is a day old.
function LibrarySync:autoCheck(wifi_event)
    local mode = self:get("auto_sync", "off")
    if mode == "off" or Job.pid or self:get("server", "") == "" then return end
    if not (wifi_event or wifiOn()) then return end
    local now = os.time()
    local last_try = self:get("auto_last", 0)
    if now - last_try < 3600 then return end
    local cfg = self:config()
    if mode == "wifi" then
        if not wifi_event then return end
        cfg.quick = true
    else
        local st = util.load_table(self.state_path)
        if st and st.last_sync and now - st.last_sync < 86400 then return end
    end
    self:set("auto_last", now)
    cfg.auto = true
    self:runSync(cfg)
end

function LibrarySync:onNetworkConnected()
    -- give the connection a moment to settle
    UIManager:scheduleIn(5, function() self:autoCheck(true) end)
end
function LibrarySync:onResume()
    UIManager:scheduleIn(10, function() self:autoCheck(false) end)
end

--- What the Library takes on the device (from the sizes the sync recorded) and what is free.
function LibrarySync:storageText()
    local st = util.load_table(self.state_path)
    local used = 0
    for _k, rec in pairs(st and st.files or {}) do
        for _p, size in pairs(rec) do used = used + (tonumber(size) or 0) end
    end
    local free = util.free_space(self:get("base", defaultBase())) or util.free_space(DataStorage:getDataDir())
    local function mb(n) return n >= 1073741824 and string.format("%.1f GB", n / 1073741824) or string.format("%.0f MB", n / 1048576) end
    return T(_("Storage: Library %1 · %2 free"), mb(used), free and mb(free) or "?")
end

--- Mark the open book as finished: KOReader's own status, and 100% for the next sync.
function LibrarySync:markFinished()
    if not (self.ui and self.ui.document) then return end
    local ds = self.ui.doc_settings
    if ds then
        local summary = ds:readSetting("summary") or {}
        summary.status = "complete"
        summary.modified = os.date("%Y-%m-%d", os.time())
        ds:saveSetting("summary", summary)
        if ds.flush then ds:flush() end
    end
    self:notePosition(true, 1)
    UIManager:show(InfoMessage:new{
        text = self.book_key and _("Marked as finished. The next sync tells the Library and Hardcover.")
            or _("Marked as finished (this book did not come from the Library, so nothing is sent)."),
        timeout = 3 })
end

-- Called in the sync process: books whose KOReader status is "finished" (set in the reader or
-- the file browser) and that were not sent yet are queued as 100%.
function LibrarySync.collectFinished(state, positions_path, state_path)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then return end
    local pending = util.load_table(positions_path) or {}
    local sent = state.finished or {}
    local changed = false
    for key, rec in pairs(state.files or {}) do
        if not sent[key] and key:match("^dl%d+$") then
            for path in pairs(rec) do
                if DocSettings:hasSidecarFile(path) then
                    local ds = DocSettings:open(path)
                    local summary = ds and ds:readSetting("summary")
                    if summary and summary.status == "complete" then
                        if not (pending[key] and pending[key].percent == 1) then
                            pending[key] = { percent = 1, at = os.time(), tz = 0 }
                            changed = true
                        end
                        sent[key] = true
                        break
                    end
                end
            end
        end
    end
    if changed then util.save_table(positions_path, pending) end
    if next(sent) then
        sync.update_state({ state_path = state_path }, function(st) st.finished = sent end)
    end
end

function LibrarySync:get(k, d)
    local v = self.settings:readSetting(k)
    if v == nil then return d end
    return v
end

function LibrarySync:set(k, v)
    self.settings:saveSetting(k, v)
    self.settings:flush()
end

function LibrarySync:config()
    return {
        server = util.normalize_server(self:get("server", "")),
        auth = self:get("auth", "basic"),
        username = self:get("username", ""),
        password = self:get("password", ""),
        token = self:get("token", ""),
        base = self:get("base", defaultBase()),
        series_in_names = self:get("series_in_names", true),
        state_path = self.state_path,
        catalog_path = DataStorage:getSettingsDir() .. "/librarysync_catalog.lua",
        summaries_path = DataStorage:getSettingsDir() .. "/librarysync_summaries.lua",
        positions_path = self:get("send_progress", true)
            and DataStorage:getSettingsDir() .. "/librarysync_positions.lua" or nil,
        skip_folders = self:get("skip_folders", {}),
        min_free = self:get("min_free_mb", 100) * 1048576,
        collect_finished = self:get("send_progress", true) and function(state)
            LibrarySync.collectFinished(state, DataStorage:getSettingsDir() .. "/librarysync_positions.lua", self.state_path)
        end or nil,
        free_space = util.free_space,
    }
end

function LibrarySync:ask(title, key, hint, is_password, after)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self:get(key, ""),
        input_hint = hint,
        text_type = is_password and "password" or nil,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                self:set(key, util.trim(dialog:getInputText()))
                UIManager:close(dialog)
                if after then after() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibrarySync:lastSyncText()
    local st = util.load_table(self.state_path)
    if st and st.last_sync then return os.date("%Y-%m-%d %H:%M", st.last_sync) end
    return _("never")
end

function LibrarySync:addToMainMenu(menu_items)
    if self.ui and self.ui.document then
        menu_items.librarysync_finished = {
            text = _("Library: mark this book as finished"),
            sorting_hint = "tools",
            callback = function() self:markFinished() end,
        }
    end
    menu_items.librarysync = {
        text = _("Library"),
        sorting_hint = "tools",
        callback = function() self:browse() end,
    }
    menu_items.librarysync_settings = {
        text = _("Library sync settings"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Sync now"), callback = function() self:syncNow() end },
            { text = _("Quick sync (only new books)"),
              help_text = _("Only asks for the books added since the last sync. Run a full sync now and then to catch books moved between folders or removed."),
              callback = function()
                  local cfg = self:checkReady()
                  if cfg then cfg.quick = true self:runSync(cfg) end
              end },
            { text_func = function() return T(_("Sync automatically: %1"), AUTO_LABELS[self:get("auto_sync", "off")] or _("off")) end,
              keep_menu_open = true,
              help_text = _("When Wi-Fi connects: a quick sync each time (at most once an hour). Once a day: a full sync when Wi-Fi is on and the last one is a day old. Wi-Fi is never turned on for it."),
              callback = function(tm)
                  self:set("auto_sync", AUTO_NEXT[self:get("auto_sync", "off")] or "off")
                  if tm and tm.updateItems then tm:updateItems() end
              end },
            { text_func = function() return T(_("Last sync: %1"), self:lastSyncText()) end,
              keep_menu_open = true, callback = function() end },
            { text_func = function()
                  if not Job.pid then return _("Sync status: not running") end
                  return T(_("Sync status: %1"), self:jobProgress() or _("starting…"))
              end,
              keep_menu_open = true,
              callback = function(tm) if tm and tm.updateItems then tm:updateItems() end end },
            { text = _("Stop the running sync"), keep_menu_open = true,
              enabled_func = function() return Job.pid ~= nil end,
              callback = function(tm)
                  self:stopJob()
                  if tm and tm.updateItems then tm:updateItems() end
              end },
            { text_func = function() return T(_("Server address: %1"), self:get("server", "") ~= "" and self:get("server") or _("not set")) end,
              keep_menu_open = true,
              callback = function(tm)
                  self:ask(_("Library server address"), "server", "https://library.example.com", false,
                      function() tm:updateItems() end)
              end },
            { text_func = function()
                  return T(_("Sign in with: %1"), self:get("auth", "basic") == "bearer" and _("API token") or _("user name and password"))
              end,
              keep_menu_open = true,
              callback = function(tm)
                  self:set("auth", self:get("auth", "basic") == "bearer" and "basic" or "bearer")
                  tm:updateItems()
              end },
            { text = _("User name"), keep_menu_open = true,
              enabled_func = function() return self:get("auth", "basic") == "basic" end,
              callback = function() self:ask(_("User name"), "username", "", false) end },
            { text = _("Password"), keep_menu_open = true,
              enabled_func = function() return self:get("auth", "basic") == "basic" end,
              callback = function() self:ask(_("Password"), "password", "", true) end },
            { text = _("API token"), keep_menu_open = true,
              enabled_func = function() return self:get("auth", "basic") == "bearer" end,
              callback = function() self:ask(_("API token"), "token", "", true) end },
            { text_func = function() return T(_("Download folder: %1"), self:get("base", defaultBase())) end,
              keep_menu_open = true,
              callback = function(tm)
                  local PathChooser = require("ui/widget/pathchooser")
                  UIManager:show(PathChooser:new{
                      select_directory = true, select_file = false, show_files = false,
                      path = self:get("base", defaultBase()),
                      onConfirm = function(path)
                          self:set("base", path)
                          tm:updateItems()
                      end,
                  })
              end },
            { text = _("Open the Library when KOReader starts"), keep_menu_open = true,
              checked_func = function() return self:get("open_on_start", false) end,
              callback = function() self:set("open_on_start", not self:get("open_on_start", false)) end },
            { text = _("Put series in file names"), keep_menu_open = true,
              checked_func = function() return self:get("series_in_names", true) end,
              callback = function() self:set("series_in_names", not self:get("series_in_names", true)) end },
            { text = _("Sync in the background"), keep_menu_open = true,
              help_text = _("Keep reading while the sync runs. Turn off to show the progress on screen instead."),
              checked_func = function() return self:get("background", true) end,
              callback = function() self:set("background", not self:get("background", true)) end },
            { text = _("Folders to sync"), callback = function() self:chooseFolders() end },
            { text_func = function() return self:storageText() end, keep_menu_open = true,
              callback = function(tm) if tm and tm.updateItems then tm:updateItems() end end },
            { text_func = function() return T(_("Keep free at least: %1 MB"), self:get("min_free_mb", 100)) end,
              keep_menu_open = true,
              help_text = _("A sync pauses before a download would leave less free space than this."),
              callback = function(tm)
                  local cur, nxt = self:get("min_free_mb", 100), MIN_FREE[1]
                  for i, v in ipairs(MIN_FREE) do if v == cur then nxt = MIN_FREE[i % #MIN_FREE + 1] end end
                  self:set("min_free_mb", nxt)
                  if tm and tm.updateItems then tm:updateItems() end
              end },
            { text = _("Remove books deleted on the server"), callback = function() self:cleanupBooks() end },
            { text = _("Send reading progress to the Library"), keep_menu_open = true,
              help_text = _("While you read, your place is saved on the device. The next sync sends it to the Library server, which passes it on to Hardcover."),
              checked_func = function() return self:get("send_progress", true) end,
              callback = function() self:set("send_progress", not self:get("send_progress", true)) end },
            { text = _("Test connection"), callback = function() self:testConnection() end },
        },
    }
end

--- Tick the Library folders that Sync now downloads (all by default; new folders are synced).
function LibrarySync:chooseFolders()
    local cat = util.load_table(self:config().catalog_path)
    if not (cat and cat.folders and #cat.folders > 0) then
        UIManager:show(InfoMessage:new{ text = _("Run a sync first: the list of folders comes from the server.") })
        return
    end
    local Menu = require("ui/widget/menu")
    local menu
    local function build()
        local skip = self:get("skip_folders", {})
        local items = {}
        for _i, f in ipairs(cat.folders) do
            items[#items + 1] = {
                text = f.name, mandatory = skip[f.name] and _("Off") or _("On"),
                callback = function()
                    local s2 = self:get("skip_folders", {})
                    s2[f.name] = not s2[f.name] or nil
                    self:set("skip_folders", s2)
                    menu:switchItemTable(nil, build(), _i)
                end,
            }
        end
        return items
    end
    menu = Menu:new{
        title = _("Folders to sync"), subtitle = _("Off: not downloaded (books already there stay)"),
        item_table = build(), is_popout = false, covers_fullscreen = true,
        is_borderless = true, title_bar_fm_style = true,
        width = require("device").screen:getWidth(), height = require("device").screen:getHeight(),
        onMenuSelect = function(_m, item) item.callback() return true end,
        close_callback = function()
            local m = menu
            menu = nil
            if m then UIManager:close(m) end
        end,
    }
    UIManager:show(menu)
end

--- List the books the plugin downloaded that are no longer on the server (or no longer in
-- that folder), and delete them after a confirmation.
function LibrarySync:cleanupBooks()
    local cfg = self:config()
    local paths, why = sync.cleanup_candidates(cfg, util.load_table(cfg.catalog_path), util.load_table(cfg.state_path))
    if not paths then
        UIManager:show(InfoMessage:new{ text = T(_("Cannot check yet: %1."), why) })
        return
    end
    if #paths == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing to remove: every downloaded book is still on the server."), timeout = 4 })
        return
    end
    local lines = {}
    for i = 1, math.min(12, #paths) do
        lines[#lines + 1] = "• " .. paths[i]:sub(#cfg.base + 2)
    end
    if #paths > 12 then lines[#lines + 1] = T(_("… and %1 more"), #paths - 12) end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1 books that are no longer on the Library server (as of the last sync)?\n\n%2"),
            #paths, table.concat(lines, "\n")),
        ok_text = _("Delete"),
        ok_callback = function()
            local n = sync.cleanup(cfg, paths)
            UIManager:show(InfoMessage:new{ text = T(_("Removed %1 books."), n), timeout = 3 })
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            if ok and FileManager.instance then FileManager.instance:onRefresh() end
            local b = Job.browser
            if b and b.menu then b:refresh() end
        end,
    })
end

-- Reading progress: remember the place of a book this plugin downloaded; the next sync sends it.
function LibrarySync:notePosition(force, forced_percent)
    if not (self.ui and self.ui.document and self.ui.document.file) then return end
    if not self:get("send_progress", true) then return end
    local now = os.time()
    if not force and self.last_note and now - self.last_note < 60 then return end
    local pages = self.ui.document.getPageCount and self.ui.document:getPageCount()
    local page = self.current_page
    local percent = forced_percent
    if not percent then
        if not (pages and pages > 0 and page) then return end
        percent = math.min(1, page / pages)
    end
    local ds = self.ui.doc_settings
    local summary = ds and ds.readSetting and ds:readSetting("summary")
    if summary and summary.status == "complete" then percent = 1 end
    if self.last_percent == percent and not force then return end
    local path = self.ui.document.file
    local key = self.book_key
    if key == nil then
        key = sync.key_for_path(util.load_table(self.state_path), path) or false
        self.book_key = key
    end
    if not key then return end
    self.last_note, self.last_percent = now, percent
    local positions_path = DataStorage:getSettingsDir() .. "/librarysync_positions.lua"
    local pending = util.load_table(positions_path) or {}
    local tz = math.floor((os.time() - os.time(os.date("!*t"))) / 60)
    pending[key] = { percent = percent, at = now, tz = -tz }
    util.save_table(positions_path, pending)
end

function LibrarySync:onReaderReady() self.book_key, self.last_percent = nil, nil end
function LibrarySync:onPageUpdate(page) self.current_page = page self:notePosition(false) end
function LibrarySync:onCloseDocument() self:notePosition(true) end
function LibrarySync:onSuspend() self:notePosition(true) end
function LibrarySync:onEndOfBook() self:notePosition(true) end

function LibrarySync:checkReady()
    local cfg = self:config()
    if not cfg.server then
        UIManager:show(InfoMessage:new{ text = _("Set the server address first (Tools ▸ Library sync settings ▸ Server address).") })
        return nil
    end
    return cfg
end

function LibrarySync:testConnection()
    local cfg = self:checkReady()
    if not cfg then return end
    NetworkMgr:runWhenOnline(function()
        local wait = InfoMessage:new{ text = _("Connecting…"), timeout = 0 }
        UIManager:show(wait)
        UIManager:forceRePaint()
        UIManager:nextTick(function()
            local httpmod = require("librarysync/http")
            cfg.transport, cfg.headers = httpmod.get, httpmod.auth_headers(cfg)
            local feed, err = sync.fetch_feed(cfg, cfg.server .. "/opds")
            UIManager:close(wait)
            UIManager:show(InfoMessage:new{
                text = feed and T(_("Connected to “%1”."), feed.title ~= "" and feed.title or cfg.server)
                    or T(_("Could not connect: %1"), tostring(err)),
            })
        end)
    end)
end

function LibrarySync:browse()
    if not self.browser then self.browser = require("librarysync/browser"):new(self) end
    self.browser:start()
end
function LibrarySync:onLibraryBrowse() self:browse() return true end


function LibrarySync:openSettings()
    -- The settings live in the main menu; show them as a stand-alone menu here (used from
    -- inside the Library). Toggles show On/Off and the list is rebuilt after each change.
    local Menu = require("ui/widget/menu")
    local menu
    local function build()
        local tmp = {}
        self:addToMainMenu(tmp)
        local items = {}
        for _i, it in ipairs(tmp.librarysync_settings.sub_item_table) do
            local enabled = not it.enabled_func or it.enabled_func()
            local item = { text = it.text_func and it.text_func() or it.text, dim = not enabled or nil }
            if it.checked_func then item.mandatory = it.checked_func() and _("On") or _("Off") end
            item.callback = function()
                if not enabled then return end
                if it.keep_menu_open then
                    local function refresh()
                        if menu then menu:switchItemTable(nil, build(), -1) end
                    end
                    if it.callback then it.callback({ updateItems = refresh }) end
                    refresh()
                else
                    local m = menu
                    menu = nil
                    if m then UIManager:close(m) end
                    if it.callback then it.callback({ updateItems = function() end }) end
                end
            end
            items[#items + 1] = item
        end
        return items
    end
    menu = Menu:new{
        title = _("Library sync settings"), item_table = build(), is_popout = false, covers_fullscreen = true,
        is_borderless = true, title_bar_fm_style = true,
        width = require("device").screen:getWidth(), height = require("device").screen:getHeight(),
        onMenuSelect = function(_m, item) item.callback() return true end,
        close_callback = function()
            local m = menu
            menu = nil
            if m then UIManager:close(m) end
        end,
    }
    UIManager:show(menu)
end

function LibrarySync:openFile(path)
    -- showReader closes the file browser (or the current book) itself once the book opens;
    -- closing the file browser first would leave nothing on screen if opening failed.
    require("apps/reader/readerui"):showReader(path)
end

function LibrarySync:syncNow() self:runSync(self:checkReady()) end

local function jobPaths()
    local dir = DataStorage:getSettingsDir()
    return dir .. "/librarysync_progress.txt", dir .. "/librarysync_stop", dir .. "/librarysync_result.lua"
end

function LibrarySync:jobProgress()
    local progress_path = jobPaths()
    local f = io.open(progress_path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text ~= "" and text or nil
end

function LibrarySync:stopJob()
    if not Job.pid then return end
    local _p, stop_path = jobPaths()
    local f = io.open(stop_path, "wb")
    if f then f:write("stop") f:close() end
    UIManager:show(InfoMessage:new{ text = _("Stopping the sync after the current step…"), timeout = 3 })
end

local function notify(text)
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and type(Notification) == "table" and Notification.notify then
        Notification:notify(text)
    else
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
    end
end

function LibrarySync:runSync(cfg)
    if not cfg then return end
    if Job.pid then
        if cfg.auto then return end
        UIManager:show(InfoMessage:new{
            text = T(_("A sync is already running.\n%1"), self:jobProgress() or ""), timeout = 4 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        if Job.pid then return end
        if (cfg.auto or self:get("background", true)) and self:startJob(cfg) then return end
        if cfg.auto then return end  -- never block the screen for an automatic sync
        self:runForeground(cfg)
    end)
end

-- What the sync result says, for the closing message.
local function summary(res, cfg)
    local lines = {}
    if res.error and not res.cancelled and not res.storage_full then
        lines[#lines + 1] = T(_("Sync failed: %1"), res.error)
    else
        if res.storage_full then
            lines[#lines + 1] = T(_("Sync paused: %1. Free some space (or lower “Keep free at least”) and sync again."), res.error)
        elseif res.cancelled then
            lines[#lines + 1] = _("Sync stopped. Run it again to continue.")
        elseif res.quick then
            lines[#lines + 1] = T(_("Quick sync finished: %1 new books on the server."), res.new_books or 0)
        else
            lines[#lines + 1] = _("Sync finished.")
        end
        lines[#lines + 1] = T(_("Downloaded: %1"), res.downloaded or 0)
        lines[#lines + 1] = T(_("Already there: %1"), res.skipped or 0)
        local failed = res.failed or {}
        if #failed > 0 then
            lines[#lines + 1] = T(_("Failed: %1 (they will be retried next time)"), #failed)
            for i = 1, math.min(5, #failed) do
                lines[#lines + 1] = "• " .. tostring(failed[i].name) .. ": " .. tostring(failed[i].error)
            end
        end
        if (res.positions or 0) > 0 then
            lines[#lines + 1] = T(_("Reading progress sent: %1 books"), res.positions)
        end
        lines[#lines + 1] = T(_("Folder: %1"), cfg.base)
    end
    return table.concat(lines, "\n")
end

local function afterSync()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager.instance then FileManager.instance:onRefresh() end
    local b = Job.browser
    if b and b.menu then b:refreshMarks() end
end

--- Run the sync in a forked process so KOReader stays usable. Returns false if it cannot fork.
function LibrarySync:startJob(cfg)
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if not ok_ffi or not ffiutil.runInSubProcess or not ffiutil.isSubProcessDone then return false end
    local progress_path, stop_path, result_path = jobPaths()
    os.remove(stop_path)
    os.remove(result_path)
    os.remove(progress_path)
    local pid = ffiutil.runInSubProcess(function()
        local last, stop = 0, false
        cfg.progress = function(text)
            local now = os.time()
            if now ~= last then
                last = now
                local f = io.open(progress_path, "wb")
                if f then f:write(text) f:close() end
                stop = lfs.attributes(stop_path, "mode") ~= nil
            end
            return not stop
        end
        local ok, res = pcall(sync.run, cfg)
        if not ok then res = { error = tostring(res), downloaded = 0, skipped = 0, failed = {} } end
        util.save_table(result_path, res)
    end)
    if not pid then return false end
    Job.pid = pid
    if not cfg.auto then notify(_("Library sync started in the background.")) end
    local function poll()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(2, poll)
            return
        end
        local res = util.load_table(result_path)
            or { error = _("the sync process ended without a result"), downloaded = 0, skipped = 0, failed = {} }
        Job.pid = nil
        os.remove(stop_path)
        os.remove(progress_path)
        local quiet = not res.error and #(res.failed or {}) == 0
        if cfg.auto then
            -- automatic: a short note only when something happened
            if res.error then
                notify(T(_("Library auto-sync: %1"), res.error))
            elseif (res.downloaded or 0) > 0 then
                notify(T(_("Library: %1 new books downloaded."), res.downloaded))
            end
        elseif quiet and (res.downloaded or 0) == 0 and not res.cancelled then
            notify(_("Library sync: everything is already on the device."))
        else
            UIManager:show(InfoMessage:new{ text = summary(res, cfg), timeout = quiet and 6 or nil })
        end
        afterSync()
    end
    UIManager:scheduleIn(2, poll)
    return true
end

--- On-screen sync with a "tap to stop" progress message (setting "Sync in the background" off,
-- or when KOReader cannot start a background process).
function LibrarySync:runForeground(cfg)
    Trapper:wrap(function()
        Trapper:info(_("Library sync: reading the server…"))
        local last = 0
        cfg.progress = function(text)
            -- Trapper:info returns false when the user taps the message to stop.
            -- Throttled: it is called for every received chunk.
            local now = os.time()
            if now == last then return true end
            last = now
            return Trapper:info(T(_("Library sync (tap to stop)\n%1"), text))
        end
        local ok, res = pcall(sync.run, cfg)
        if not ok then res = { error = tostring(res), failed = {} } end
        Trapper:clear()
        UIManager:show(InfoMessage:new{ text = summary(res, cfg) })
        afterSync()
    end)
end

return LibrarySync
