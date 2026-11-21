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
            { text_func = function() return T(_("Last sync: %1"), self:lastSyncText()) end, keep_menu_open = true, callback = function() end },
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
            { text = _("Test connection"), callback = function() self:testConnection() end },
        },
    }
end

function LibrarySync:checkReady()
    local cfg = self:config()
    if not cfg.server then
        UIManager:show(InfoMessage:new{ text = _("Set the server address first (Library sync ▸ Server address).") })
        return nil
    end
    return cfg
end

function LibrarySync:testConnection()
    local cfg = self:checkReady()
    if not cfg then return end
    NetworkMgr:runWhenOnline(function()
        local httpmod = require("librarysync/http")
        cfg.transport, cfg.headers = httpmod.get, httpmod.auth_headers(cfg)
        local feed, err = sync.fetch_feed(cfg, cfg.server .. "/opds")
        UIManager:show(InfoMessage:new{
            text = feed and T(_("Connected to “%1”."), feed.title ~= "" and feed.title or cfg.server)
                or T(_("Could not connect: %1"), tostring(err)),
        })
    end)
end

function LibrarySync:browse()
    if not self.browser then self.browser = require("librarysync/browser"):new(self) end
    self.browser:start()
end
function LibrarySync:onLibraryBrowse() self:browse() return true end

function LibrarySync:openSettings()
    -- The settings live in the main menu; show them as a stand-alone menu here.
    local Menu = require("ui/widget/menu")
    local items = {}
    local tmp = {}
    self:addToMainMenu(tmp)
    local tbl = tmp.librarysync_settings.sub_item_table
    for _, it in ipairs(tbl) do
        local item = { text = it.text_func and it.text_func() or it.text, enabled = true }
        item.callback = function()
            if it.callback then it.callback({ updateItems = function() end }) end
            UIManager:close(self.settings_menu)
            self.settings_menu = nil
        end
        items[#items + 1] = item
    end
    self.settings_menu = Menu:new{
        title = _("Library sync settings"), item_table = items, is_popout = false, covers_fullscreen = true,
        width = require("device").screen:getWidth(), height = require("device").screen:getHeight(),
        onMenuSelect = function(_, item) item.callback() return true end,
    }
    UIManager:show(self.settings_menu)
end

function LibrarySync:openFile(path)
    local ReaderUI = require("apps/reader/readerui")
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then FileManager.instance:onClose() end
    ReaderUI:showReader(path)
end

function LibrarySync:syncNow() self:runSync(self:checkReady()) end

function LibrarySync:runSync(cfg)
    if not cfg then return end
    NetworkMgr:runWhenOnline(function()
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
            local res = sync.run(cfg)
            local lines = {}
            if res.error and not res.cancelled then
                lines[#lines + 1] = T(_("Sync failed: %1"), res.error)
            else
                lines[#lines + 1] = res.cancelled and _("Sync stopped. Run it again to continue.") or _("Sync finished.")
                lines[#lines + 1] = T(_("Downloaded: %1"), res.downloaded)
                lines[#lines + 1] = T(_("Already there: %1"), res.skipped)
                if #res.failed > 0 then
                    lines[#lines + 1] = T(_("Failed: %1 (they will be retried next time)"), #res.failed)
                    for i = 1, math.min(5, #res.failed) do
                        lines[#lines + 1] = "• " .. res.failed[i].name .. ": " .. res.failed[i].error
                    end
                end
                lines[#lines + 1] = T(_("Folder: %1"), cfg.base)
            end
            UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            if ok and FileManager.instance then FileManager.instance:onRefresh() end
        end)
    end)
end

return LibrarySync
