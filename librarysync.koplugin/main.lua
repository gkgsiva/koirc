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
    -- Once per KOReader launch, open the catalog over the file manager.
    if self.ui.file_chooser and self:get("open_on_start", false) and not LibrarySync.started then
        LibrarySync.started = true
        UIManager:scheduleIn(1, function()
            if self:get("server", "") ~= "" then self:browse() end
        end)
    end
end

function LibrarySync:onLibrarySyncNow() self:syncNow() return true end

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
            { text = _("Test connection"), callback = function() self:testConnection() end },
        },
    }
end

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
        UIManager:show(InfoMessage:new{
            text = T(_("A sync is already running.\n%1"), self:jobProgress() or ""), timeout = 4 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        if Job.pid then return end
        if self:get("background", true) and self:startJob(cfg) then return end
        self:runForeground(cfg)
    end)
end

-- What the sync result says, for the closing message.
local function summary(res, cfg)
    local lines = {}
    if res.error and not res.cancelled then
        lines[#lines + 1] = T(_("Sync failed: %1"), res.error)
    else
        lines[#lines + 1] = res.cancelled and _("Sync stopped. Run it again to continue.") or _("Sync finished.")
        lines[#lines + 1] = T(_("Downloaded: %1"), res.downloaded or 0)
        lines[#lines + 1] = T(_("Already there: %1"), res.skipped or 0)
        local failed = res.failed or {}
        if #failed > 0 then
            lines[#lines + 1] = T(_("Failed: %1 (they will be retried next time)"), #failed)
            for i = 1, math.min(5, #failed) do
                lines[#lines + 1] = "• " .. tostring(failed[i].name) .. ": " .. tostring(failed[i].error)
            end
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
    notify(_("Library sync started in the background."))
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
        if quiet and (res.downloaded or 0) == 0 and not res.cancelled then
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
