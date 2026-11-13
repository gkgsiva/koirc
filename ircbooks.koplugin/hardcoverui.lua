--[[--
Hardcover screens for the IRC book search plugin: the user's lists, the books
in a list with whether each has a file on the device, a "next book" flow that
searches IRC for one missing book after another, background downloads of
several books, and updating the reading status when a book is opened or
finished.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Hardcover = require("koirc/hardcover")

local TOKEN_FILE = "hardcover.txt"

local function loadJson()
    local ok, json = pcall(require, "json")
    if ok and json and json.encode and json.decode then return json end
    local rok, rapidjson = pcall(require, "rapidjson")
    if rok and rapidjson then return rapidjson end
    return nil
end

-- Connect and read timeouts (seconds) for Hardcover requests. Requests
-- block the screen, so background updates (reading status, progress) use
-- short ones; screens the user waits for use the longer default.
local TIMEOUTS_NORMAL = { 15, 45 }
local TIMEOUTS_QUICK = { 5, 10 }
local timeouts = TIMEOUTS_NORMAL

--- Blocking HTTPS POST using KOReader's LuaSocket/LuaSec.
local function httpPost(url, headers, body)
    local ltn12 = require("ltn12")
    local http = require("socket.http")
    local has_https, https = pcall(require, "ssl.https")
    local su_ok, socketutil = pcall(require, "socketutil")
    if su_ok and socketutil.set_timeout then socketutil:set_timeout(timeouts[1], timeouts[2]) end
    local chunks = {}
    local request = {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(chunks),
    }
    local requester = http.request
    if has_https and url:sub(1, 6) == "https:" and https.request then requester = https.request end
    local ok, r1, code = pcall(requester, request)
    if su_ok and socketutil.reset_timeout then socketutil:reset_timeout() end
    if not ok then return nil, tostring(r1) end
    if not r1 then return nil, tostring(code) end
    return code, table.concat(chunks)
end

local function notify(text)
    local ok = pcall(function()
        local Notification = require("ui/widget/notification")
        if Notification.notify then
            Notification:notify(text)
        else
            UIManager:show(Notification:new{ text = text })
        end
    end)
    if not ok then UIManager:show(InfoMessage:new{ text = text, timeout = 3 }) end
end

local function fileExists(path)
    return path and lfs.attributes(path, "mode") == "file"
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local HardcoverUI = {}
HardcoverUI.__index = HardcoverUI

-- Shared by the file browser's and the reader's plugin instances.
-- Store: the lists, shelves and series saved from Hardcover. They live in
-- their own file rather than in KOReader's settings.reader.lua, which
-- KOReader rewrites on every book close, suspend and many settings changes;
-- a large saved library there slowed down all of KOReader.
local Store = { data = nil, version = 0 }
-- Book files found on the device, reused for a while instead of walking
-- the folders every time a list is opened.
local Scan = { files = nil, at = 0 }
local SCAN_TTL = 600
-- Files already looked up that are not a Hardcover book.
local NoMatch = {}

local function storePath()
    local dir = DataStorage.getSettingsDir and DataStorage:getSettingsDir()
             or (DataStorage:getDataDir() .. "/settings")
    return dir .. "/ircbooks_hardcover.lua"
end

function HardcoverUI.new(plugin)
    local self = setmetatable({}, HardcoverUI)
    self.plugin = plugin
    self.json = loadJson()
    self.client = Hardcover.new{
        post = httpPost,
        json = self.json,
        token = function() return self:getToken() end,
    }
    return self
end

function HardcoverUI:settings()
    return self.plugin.settings
end

--- The saved Hardcover data (cache key -> data), loaded on first use.
function HardcoverUI:cache()
    if Store.data then return Store.data end
    local LuaSettings = require("luasettings")
    local ok, file = pcall(LuaSettings.open, LuaSettings, storePath())
    Store.file = ok and file or nil
    Store.data = Store.file and Store.file:readSetting("cache") or {}
    -- Move the copy older versions kept in settings.reader.lua.
    local s = self:settings()
    if type(s.hardcover_cache) == "table" then
        if next(Store.data) == nil then Store.data = s.hardcover_cache end
        s.hardcover_cache = nil
        self.plugin:saveSettings()
        self:saveCache()
        pcall(function() G_reader_settings:flush() end)
    end
    return Store.data
end

function HardcoverUI:setCache(data)
    Store.data = data
    self:saveCache()
end

function HardcoverUI:saveCache()
    Store.version = Store.version + 1
    Store.all_books = nil
    NoMatch = {}
    if not Store.file then return end
    Store.file:saveSetting("cache", Store.data or {})
    local ok, err = pcall(Store.file.flush, Store.file)
    if not ok then logger.warn("ircbooks: could not save Hardcover data:", err) end
end

--- Book files on the device, scanned again after SCAN_TTL seconds or when
-- forgetFiles was called (after a download or "Refresh attached books").
function HardcoverUI:localFiles()
    if not Scan.files or os.time() - Scan.at > SCAN_TTL then self:scanLocalFiles() end
    return Scan.files
end

function HardcoverUI:forgetFiles()
    Scan.files = nil
    NoMatch = {}
end

--- Folders where a hardcover.txt holding the API key may be dropped.
function HardcoverUI:tokenFileCandidates()
    local dirs = {
        DataStorage:getDataDir(),
        DataStorage.getSettingsDir and DataStorage:getSettingsDir() or false,
        G_reader_settings:readSetting("home_dir") or false,
        Device.home_dir or false,
        self.plugin:getDownloadDir(),
    }
    local paths, seen = {}, {}
    for i = 1, 5 do
        local d = dirs[i]
        if d and not seen[d] then
            seen[d] = true
            paths[#paths + 1] = d .. "/" .. TOKEN_FILE
        end
    end
    return paths
end

function HardcoverUI:findTokenFile()
    for _i, p in ipairs(self:tokenFileCandidates()) do
        if fileExists(p) then return p end
    end
end

function HardcoverUI:getToken()
    local s = self:settings()
    if s.hardcover_token and s.hardcover_token ~= "" then return s.hardcover_token end
    local path = self:findTokenFile()
    if path then
        local token = Hardcover.cleanToken(readFile(path))
        if token ~= "" then
            s.hardcover_token = token
            self.plugin:saveSettings()
            logger.info("ircbooks: loaded Hardcover API key from", path)
            return token
        end
    end
    return ""
end

function HardcoverUI:hasToken()
    return self:getToken() ~= ""
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

function HardcoverUI:getSettingsItem()
    return {
        text_func = function()
            return T(_("Hardcover API key: %1"), self:hasToken() and "••••" or _("not set"))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showTokenDialog(function()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end)
        end,
    }
end

function HardcoverUI:showTokenDialog(on_done)
    local s = self:settings()
    local dialog
    local function done()
        UIManager:close(dialog)
        if on_done then on_done() end
    end
    dialog = InputDialog:new{
        title = _("Hardcover API key"),
        input = s.hardcover_token or "",
        input_hint = _("Paste the key from hardcover.app/account/api"),
        description = T(_("Typing the long key is hard on an e-reader. Instead you can save it in a text file named %1 in the KOReader folder (%2) or your home folder, then tap “Load from file”."),
                        TOKEN_FILE, DataStorage:getDataDir()),
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Load from file"),
                    callback = function()
                        local path = self:findTokenFile()
                        local token = path and Hardcover.cleanToken(readFile(path)) or ""
                        if token == "" then
                            UIManager:show(InfoMessage:new{
                                text = T(_("No %1 found. Looked in:\n%2"), TOKEN_FILE,
                                         table.concat(self:tokenFileCandidates(), "\n")),
                            })
                            return
                        end
                        s.hardcover_token = token
                        self.plugin:saveSettings()
                        done()
                        UIManager:show(InfoMessage:new{ text = T(_("API key loaded from\n%1"), path), timeout = 3 })
                    end,
                },
                {
                    text = _("Clear"),
                    callback = function()
                        s.hardcover_token = ""
                        self.plugin:saveSettings()
                        done()
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        s.hardcover_token = Hardcover.cleanToken(dialog:getInputText())
                        self.plugin:saveSettings()
                        done()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Run a blocking request with a "Loading" message on screen.
function HardcoverUI:withLoading(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, a, b = pcall(fn)
    UIManager:close(msg)
    if not ok then
        logger.err("ircbooks: Hardcover request failed:", a)
        return nil, tostring(a)
    end
    return a, b
end

function HardcoverUI:makeMenu(opts)
    local menu
    menu = Menu:new{
        title = opts.title or "",
        item_table = opts.items or {},
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        -- Wrap long titles over several lines instead of cutting them off.
        multilines_show_more_text = true,
        multilines_forced = true,
        items_max_lines = 4,
        items_per_page = 8,
        onMenuSelect = function(_menu, item)
            opts.on_select(item)
            return true
        end,
        onMenuHold = function(_menu, item)
            if opts.on_hold then opts.on_hold(item) else opts.on_select(item) end
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
            if opts.on_close then opts.on_close(menu) end
        end,
    }
    return menu
end

function HardcoverUI:closeMenus()
    if self.books_menu then UIManager:close(self.books_menu) self.books_menu = nil end
    if self.series_menu then UIManager:close(self.series_menu) self.series_menu = nil end
    if self.lists_menu then UIManager:close(self.lists_menu) self.lists_menu = nil end
    self.queue = nil
    self.current = nil
end

-------------------------------------------------------------------------------
-- Lists
-------------------------------------------------------------------------------

local function isOnline()
    local ok, online = pcall(function()
        if NetworkMgr.isOnline then return NetworkMgr:isOnline() end
        return NetworkMgr:isConnected()
    end)
    return ok and online
end

local function copyWithoutPaths(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do
        if k ~= "path" then t[k] = copyWithoutPaths(x) end
    end
    return t
end

--- How to load the data stored under a cache key.
function HardcoverUI:loader(key)
    local c = self.client
    if key == "lists" then return function() return c:getLists() end end
    if key == "series" then return function() return c:getSeries() end end
    local kind, id = key:match("^books:([^:]+):(.+)$")
    if not kind then return nil end
    id = tonumber(id) or id
    if kind == "status" then return function() return c:getStatusBooks(id) end end
    if kind == "series" then return function() return c:getSeriesBooks(id) end end
    return function() return c:getListBooks(id) end
end

--- Load data, using the copy saved on the device when there is one, so
-- screens open instantly. "Sync with Hardcover" refreshes the saved copies.
-- Returns data, err. With nothing saved yet it loads from Hardcover, first
-- asking to turn Wi-Fi on if needed (then calls retry and returns nil, nil).
function HardcoverUI:fetch(key, text, retry)
    local s = self:settings()
    local cache = self:cache()
    local cached = cache[key]
    if cached then return cached end
    if not isOnline() then
        NetworkMgr:runWhenOnline(retry)
        return nil, nil
    end
    local data, err = self:withLoading(text, self:loader(key))
    if data then
        cache[key] = copyWithoutPaths(data)
        self:saveCache()
        if not s.hardcover_synced_at then
            s.hardcover_synced_at = os.time()
            self.plugin:saveSettings()
        end
    end
    return data, err
end

--- Reload everything saved on the device from Hardcover.
function HardcoverUI:sync()
    if not isOnline() then
        NetworkMgr:runWhenOnline(function() self:sync() end)
        return
    end
    local s = self:settings()
    local old = self:cache()
    local keys = { "lists", "series" }
    for key in pairs(old) do
        if key ~= "lists" and key ~= "series" then keys[#keys + 1] = key end
    end
    local fresh, failed = {}, nil
    for i, key in ipairs(keys) do
        local fn = self:loader(key)
        if fn then
            local data, err = self:withLoading(T(_("Syncing with Hardcover… (%1 of %2)"), i, #keys), fn)
            if data then
                fresh[key] = copyWithoutPaths(data)
            elseif key == "lists" then
                -- Without the lists nothing else will work either.
                failed = err or _("Could not reach Hardcover.")
                break
            else
                failed = failed or err
                fresh[key] = old[key] -- keep the old copy (e.g. a deleted list)
            end
        end
    end
    if fresh.lists then
        self:setCache(fresh)
        s.hardcover_synced_at = os.time()
        self.plugin:saveSettings()
        pcall(function() self:autoAttachAll() end)
    end
    self:flushStatus()
    self:forgetFiles()
    local reopen = self.books_menu and self.source
    local series_open = self.series_menu ~= nil
    self:closeMenus()
    if self:showLists() then
        if series_open then self:showSeries() end
        if reopen then self:showBooks(reopen) end
    end
    if failed then
        UIManager:show(InfoMessage:new{ text = T(_("Some items could not be synced:\n%1"), tostring(failed)) })
    else
        UIManager:show(InfoMessage:new{ text = _("Synced with Hardcover."), timeout = 2 })
    end
end

function HardcoverUI:open()
    if not self.json then
        UIManager:show(InfoMessage:new{ text = _("This KOReader version has no JSON module, so Hardcover cannot be used.") })
        return
    end
    if not self:hasToken() then
        self:showTokenDialog(function()
            if self:hasToken() then self:open() end
        end)
        return
    end
    self:showLists()
end

--- Open the Hardcover view and the list or series that was open last.
function HardcoverUI:openHome()
    if not self.json or not self:hasToken() then return end
    if not self:showLists() then return end
    local last = self:settings().hardcover_last_source
    if type(last) == "table" and last.kind and last.id then self:showBooks(last) end
end

function HardcoverUI:showLists()
    local res, err = self:fetch("lists", _("Loading your Hardcover lists…"), function() self:showLists() end)
    if not res then
        if err then UIManager:show(InfoMessage:new{ text = err }) end
        return
    end
    local synced = self:settings().hardcover_synced_at
    local items = {{
        text = _("Sync with Hardcover"),
        mandatory = synced and T(_("last: %1"), os.date("%d %b %H:%M", synced)) or nil,
        do_sync = true,
        bold = true,
        separator = true,
    }, {
        text = _("Refresh attached books"),
        mandatory = _("on device"),
        auto_attach = true,
    }, {
        text = _("Series tracker"),
        mandatory = _("series"),
        open_series = true,
    }, {
        text = _("Want to read"),
        mandatory = _("shelf"),
        source = { kind = "status", id = Hardcover.STATUS_WANT_TO_READ, name = _("Want to read") },
        separator = true,
    }}
    for _i, l in ipairs(res.lists) do
        items[#items + 1] = {
            text = l.name,
            mandatory = l.count and T(_("%1 books"), l.count) or nil,
            source = { kind = "list", id = l.id, name = l.name },
        }
    end
    if #res.lists == 0 then
        items[#items + 1] = { text = _("You have no lists on Hardcover yet."), dim = true }
    end
    if self.lists_menu then UIManager:close(self.lists_menu) end
    local title = res.user.username and T(_("Hardcover: %1"), res.user.username) or _("Hardcover")
    local menu
    menu = self:makeMenu{
        title = title,
        items = items,
        on_select = function(item)
            if item.do_sync then
                self:sync()
            elseif item.auto_attach then
                self:refreshAttachments()
            elseif item.open_series then
                self:showSeries()
            elseif item.source then
                self:showBooks(item.source)
            end
        end,
        on_close = function(m)
            if self.lists_menu == m then self.lists_menu = nil end
        end,
    }
    self.lists_menu = menu
    UIManager:show(menu)
    return true
end

function HardcoverUI:showSeries()
    local res, err = self:fetch("series", _("Loading your series…"), function() self:showSeries() end)
    if not res then
        if err then UIManager:show(InfoMessage:new{ text = err }) end
        return
    end
    local items = {}
    local function add(list, label)
        for i, sr in ipairs(list) do
            items[#items + 1] = {
                text = sr.name,
                mandatory = sr.count and T(_("%1 · %2 books"), label, sr.count) or label,
                source = { kind = "series", id = sr.id, name = sr.name },
                separator = i == #list,
            }
        end
    end
    add(res.following, _("following"))
    add(res.started, _("started"))
    if #items == 0 then
        items[1] = { text = _("Follow a series on Hardcover's Series Tracker to see it here."), dim = true }
    end
    if self.series_menu then UIManager:close(self.series_menu) end
    local menu
    menu = self:makeMenu{
        title = _("Series tracker"),
        items = items,
        on_select = function(item)
            if item.source then self:showBooks(item.source) end
        end,
        on_close = function(m)
            if self.series_menu == m then self.series_menu = nil end
        end,
    }
    self.series_menu = menu
    UIManager:show(menu)
end

-------------------------------------------------------------------------------
-- Books of a list
-------------------------------------------------------------------------------

function HardcoverUI:scanLocalFiles()
    local p = self.plugin
    local roots = {
        p:getDownloadDir(),
        G_reader_settings:readSetting("home_dir") or "",
        Device.home_dir or "",
    }
    Scan.files = Hardcover.scan(lfs, roots, 5, nil, self:metadataLookup())
    Scan.at = os.time()
end

--- Title and authors of a book file from the cover browser's book info
-- database, when that plugin is active and has seen the file.
function HardcoverUI:metadataLookup()
    local BookInfoManager = package.loaded["bookinfomanager"]
    if type(BookInfoManager) ~= "table" or not BookInfoManager.getBookInfo then return nil end
    local budget = 5000
    return function(path)
        if budget <= 0 then return nil end
        budget = budget - 1
        local info = BookInfoManager:getBookInfo(path, false)
        if type(info) == "table" then return { title = info.title, authors = info.authors } end
    end
end

--- Path of this book's file on the device, or nil.
function HardcoverUI:localFile(book)
    local s = self:settings()
    s.hardcover_files = s.hardcover_files or {}
    local key = tostring(book.id)
    local recorded = s.hardcover_files[key]
    -- false: the user detached the file, so don't guess from file names.
    if recorded == false then return nil end
    if recorded and fileExists(recorded) then return recorded end
    local found = Hardcover.findFile(book, self:localFiles())
    if found then
        -- Auto-attach: remember the match so it sticks, and so reading
        -- status updates know which Hardcover book the file is.
        s.hardcover_files[key] = found
        self.dirty = true
    end
    return found
end

--- Every book in the lists, shelves and series saved on the device.
function HardcoverUI:allCachedBooks()
    if Store.all_books then return Store.all_books end
    local cache = self:cache()
    local out, seen = {}, {}
    for key, books in pairs(cache) do
        if key:match("^books:") and type(books) == "table" then
            for _i, b in ipairs(books) do
                if type(b) == "table" and b.id and not seen[b.id] then
                    seen[b.id] = true
                    out[#out + 1] = b
                end
            end
        end
    end
    Store.all_books = out
    return out
end

--- Recheck attached files and attach files on the device to every saved
-- Hardcover book they match. A file that was deleted or moved is looked for
-- again (by name and title) and re-linked, or else detached.
-- Returns attached (new), relinked (moved), removed (gone) counts.
function HardcoverUI:autoAttachAll()
    local s = self:settings()
    s.hardcover_files = s.hardcover_files or {}
    self:scanLocalFiles()
    local attached, relinked, removed = 0, 0, 0
    local known = {}
    for _i, b in ipairs(self:allCachedBooks()) do
        local key = tostring(b.id)
        known[key] = true
        local had = s.hardcover_files[key]
        if had == nil or (had and not fileExists(had)) then
            if had then s.hardcover_files[key] = nil end
            if self:localFile(b) then
                if had then relinked = relinked + 1 else attached = attached + 1 end
            elseif had then
                removed = removed + 1
            end
        end
    end
    -- Files recorded for books no longer in any saved list.
    for key, path in pairs(s.hardcover_files) do
        if not known[key] and path and not fileExists(path) then
            s.hardcover_files[key] = nil
        end
    end
    self.plugin:saveSettings()
    self.dirty = false
    return attached, relinked, removed
end

--- Run autoAttachAll with a message and report what changed.
function HardcoverUI:refreshAttachments()
    local ok, a, r, d = pcall(function()
        local msg = InfoMessage:new{ text = _("Checking books on the device…") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local x, y, z = self:autoAttachAll()
        UIManager:close(msg)
        return x, y, z
    end)
    if not ok then
        logger.err("ircbooks: refreshing attached books failed:", a)
        UIManager:show(InfoMessage:new{ text = tostring(a) })
        return
    end
    self:refreshBooks()
    if a + r + d == 0 then
        UIManager:show(InfoMessage:new{ text = _("Attached books are up to date."), timeout = 3 })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Attached books refreshed:\n%1 newly attached\n%2 moved and re-linked\n%3 no longer on the device (now ✗)"), a, r, d),
        })
    end
end

function HardcoverUI:showBooks(source)
    local key = "books:" .. tostring(source.kind) .. ":" .. tostring(source.id)
    local books, err = self:fetch(key, T(_("Loading “%1”…"), source.name), function() self:showBooks(source) end)
    if not books then
        if err then UIManager:show(InfoMessage:new{ text = err }) end
        return
    end
    self:settings().hardcover_last_source = { kind = source.kind, id = source.id, name = source.name }
    self.plugin:saveSettings()
    self.source = source
    self.books = books
    if self.books_menu then UIManager:close(self.books_menu) end
    local menu
    menu = self:makeMenu{
        title = source.name,
        on_select = function(item) self:onBookSelected(item) end,
        on_hold = function(item)
            if item.book then self:showBookDialog(item.index) else self:onBookSelected(item) end
        end,
        on_close = function(m)
            if self.books_menu == m then
                self.books_menu = nil
                self.queue = nil
                self.current = nil
            end
        end,
    }
    self.books_menu = menu
    self:refreshBooks()
    UIManager:show(menu)
end

function HardcoverUI:refreshBooks()
    local menu, books = self.books_menu, self.books
    if not menu or not books then return end
    local items, missing = {}, 0
    for i, book in ipairs(books) do
        book.path = self:localFile(book)
        if not book.path then missing = missing + 1 end
        local info = {}
        if book.authors ~= "" then info[#info + 1] = book.authors end
        if book.series then info[#info + 1] = book.series end
        items[#items + 1] = {
            text = (book.path and "✓ " or "✗ ") .. book.title,
            index = i,
            book = book,
        }
        if #info > 0 then items[#items].text = items[#items].text .. " — " .. table.concat(info, " · ") end
    end
    if self.dirty then
        self.dirty = false
        self.plugin:saveSettings()
    end
    local q = self.plugin.queue
    local bg
    if q and q:isRunning() then
        bg = { text = T(_("Background downloads: %1"), q:statusText()), mandatory = _("tap to stop"), queue_status = true }
    elseif q and q:isPaused() then
        bg = { text = T(_("Background downloads paused: %1 left"), q:remaining()), mandatory = _("tap to continue"), queue_status = true }
    elseif missing > 1 then
        bg = { text = T(_("Download missing books in the background… (%1)"), missing), pick_queue = true }
    end
    if bg then
        bg.separator = true
        table.insert(items, 1, bg)
    end
    table.insert(items, 1, {
        text = missing > 0 and T(_("Download missing books one by one (%1)"), missing)
                            or _("Every book in this list is on the device"),
        mandatory = T(_("%1 of %2 on device"), #books - missing, #books),
        bold = true,
        start_queue = missing > 0,
        rescan = missing == 0,
        separator = bg == nil,
    })
    if #books == 0 then
        items[#items + 1] = { text = _("This list is empty."), dim = true }
    else
        items[#items].separator = true
        items[#items + 1] = {
            text = _("Refresh attached books (deleted or moved files)"),
            refresh_files = true,
        }
    end
    menu:switchItemTable(self.source.name, items, -1)
end

function HardcoverUI:nextMissing(after)
    local books = self.books or {}
    for i = (after or 0) + 1, #books do
        if not books[i].path then return i end
    end
end

function HardcoverUI:onBookSelected(item)
    if item.pick_queue then
        self:showQueuePicker()
        return
    end
    if item.refresh_files then
        self:refreshAttachments()
        return
    end
    if item.queue_status then
        self.plugin:showQueueDialog()
        return
    end
    if item.start_queue then
        local i = self:nextMissing(0)
        if i then self:searchBook(i) end
        return
    end
    if item.rescan then
        self:forgetFiles()
        self:refreshBooks()
        return
    end
    if not item.book then return end
    -- A book with a file opens for reading; hold it for more options.
    if item.book.path then
        self:openBook(item.book.path)
        return
    end
    self:showBookDialog(item.index)
end

function HardcoverUI:setFile(book, path)
    local s = self:settings()
    s.hardcover_files = s.hardcover_files or {}
    s.hardcover_files[tostring(book.id)] = path
    self.plugin:saveSettings()
    book.path = path or nil
    self:refreshBooks()
end

--- Let the user pick a book file already on the device for this book.
function HardcoverUI:attachFile(book, on_done)
    local PathChooser = require("ui/widget/pathchooser")
    local start = book.path and book.path:match("^(.*)/[^/]+$") or self.plugin:getDownloadDir()
    local chooser = PathChooser:new{
        title = T(_("Choose the file for “%1”"), book.title),
        select_directory = false,
        select_file = true,
        show_files = true,
        path = start,
        onConfirm = function(path)
            self:setFile(book, path)
            UIManager:show(InfoMessage:new{ text = T(_("Attached to “%1”:\n%2"), book.title, path), timeout = 3 })
            if on_done then on_done(path) end
        end,
    }
    UIManager:show(chooser)
end

function HardcoverUI:showBookDialog(i)
    local book = self.books and self.books[i]
    if not book then return end
    local dialog
    local function button(text, fn)
        return { text = text, callback = function() UIManager:close(dialog) fn() end }
    end
    local buttons
    if book.path then
        buttons = {
            { button(_("Download again from IRC"), function() self:searchBook(i) end),
              button(_("Open"), function() self:openBook(book.path) end) },
            { button(_("Attach another file…"), function() self:attachFile(book) end),
              button(_("Detach file"), function() self:setFile(book, false) end) },
            { button(_("Close"), function() end) },
        }
    else
        buttons = {
            { button(_("Attach a file I have…"), function() self:attachFile(book) end),
              button(_("Download from IRC"), function() self:searchBook(i) end) },
            { button(_("Close"), function() end) },
        }
    end
    dialog = ButtonDialog:new{
        title = book.path and T(_("%1\n\nOn device:\n%2"), book.title, book.path)
                           or T(_("%1\n\nNo file on the device yet."), book.title),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-------------------------------------------------------------------------------
-- Searching and the next-book flow
-------------------------------------------------------------------------------

--- Ask to confirm (and maybe edit) the IRC search for the book at index i.
function HardcoverUI:searchBook(i)
    local book = self.books and self.books[i]
    if not book then return end
    self.current = { index = i, book = book }
    local dialog
    local function skip()
        UIManager:close(dialog)
        local n = self:nextMissing(i)
        if n then self:searchBook(n) else self:finished() end
    end
    dialog = InputDialog:new{
        title = T(_("Search IRC for “%1”"), book.title),
        input = Hardcover.searchQuery(book),
        input_hint = _("Author and/or title"),
        description = T(_("Book %1 of %2 in “%3”"), i, #self.books, self.source.name),
        buttons = {{
            {
                text = _("I already have it: attach file…"),
                callback = function()
                    UIManager:close(dialog)
                    self:attachFile(book, function()
                        local n = self:nextMissing(i)
                        if n then self:searchBook(n) else self:finished() end
                    end)
                end,
            },
        }, {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    self.current = nil
                end,
            },
            {
                text = _("Skip"),
                callback = skip,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = (dialog:getInputText() or ""):gsub("[\r\n]", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    if query == "" then return end
                    UIManager:close(dialog)
                    self.current = { index = i, book = book }
                    NetworkMgr:runWhenOnline(function()
                        self.plugin:doSearch(query, {
                            on_empty = function() self:onNoResults(query) end,
                        })
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function HardcoverUI:onNoResults(query)
    local cur = self.current
    if not cur then return end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("No books found for “%1”."), query),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Change search"),
                    callback = function()
                        UIManager:close(dialog)
                        self:searchBook(cur.index)
                    end,
                },
                {
                    text = _("Next book"),
                    callback = function()
                        UIManager:close(dialog)
                        self:goNext(cur.index)
                    end,
                },
            },
            {{
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                    self.current = nil
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function HardcoverUI:goNext(after)
    self.plugin:closeResults()
    local n = self:nextMissing(after)
    if n then self:searchBook(n) else self:finished() end
end

function HardcoverUI:finished()
    self.current = nil
    UIManager:show(InfoMessage:new{ text = _("No more missing books in this list.") })
end

function HardcoverUI:clearCurrent()
    self.current = nil
end

--- The Hardcover book an IRC search is running for, if any.
function HardcoverUI:currentBook()
    return self.current and self.current.book or nil
end

-------------------------------------------------------------------------------
-- Background downloads
-------------------------------------------------------------------------------

--- Choose which missing books of the open list to download in the background.
function HardcoverUI:showQueuePicker()
    local books = self.books or {}
    local picked = {}
    for i, b in ipairs(books) do
        if not b.path then picked[i] = true end
    end
    local menu
    local function count()
        local n = 0
        for _i in pairs(picked) do n = n + 1 end
        return n
    end
    local function refresh()
        local items = {{
            text = T(_("Start downloading (%1 books)"), count()),
            bold = true,
            start = true,
        }, {
            text = _("Select all missing / none"),
            toggle_all = true,
            separator = true,
        }}
        for i, b in ipairs(books) do
            if not b.path then
                items[#items + 1] = {
                    text = (picked[i] and "☑ " or "☐ ") .. b.title .. (b.authors ~= "" and (" — " .. b.authors) or ""),
                    index = i,
                }
            end
        end
        menu:switchItemTable(T(_("Download in the background: %1"), self.source.name), items, -1)
    end
    menu = self:makeMenu{
        title = "",
        on_select = function(item)
            if item.start then
                local list = {}
                for i, b in ipairs(books) do
                    if picked[i] then list[#list + 1] = b end
                end
                if #list == 0 then return end
                UIManager:close(menu)
                NetworkMgr:runWhenOnline(function()
                    self.plugin.queue:start(list, self.source.name)
                    self:refreshBooks()
                end)
            elseif item.toggle_all then
                local any = count() > 0
                for i, b in ipairs(books) do
                    if not b.path then picked[i] = (not any) or nil end
                end
                refresh()
            elseif item.index then
                picked[item.index] = (not picked[item.index]) or nil
                refresh()
            end
        end,
    }
    refresh()
    UIManager:show(menu)
end

--- A background download finished: remember the file for the book.
function HardcoverUI:onQueuedDownload(book, path)
    local s = self:settings()
    s.hardcover_files = s.hardcover_files or {}
    s.hardcover_files[tostring(book.id)] = path
    self.plugin:saveSettings()
    for _i, b in ipairs(self.books or {}) do
        if b.id == book.id then b.path = path end
    end
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
end

-------------------------------------------------------------------------------
-- Reading status on Hardcover
-------------------------------------------------------------------------------

function HardcoverUI:getStatusSyncItem()
    return {
        text = _("Update reading status on Hardcover"),
        help_text = _("When you open a book that is in your Hardcover lists, mark it as Currently reading; when you finish it, mark it as Read."),
        checked_func = function() return self:settings().hardcover_status_sync ~= false end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local s = self:settings()
            s.hardcover_status_sync = s.hardcover_status_sync == false
            self.plugin:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
end

--- The Hardcover book a file on the device is, if any. Uses attached files
-- first, then matches the file name and the book's own title and authors
-- against the books saved from Hardcover (and remembers such a match).
function HardcoverUI:bookForFile(path, props)
    if NoMatch[path] then return nil end
    local s = self:settings()
    s.hardcover_files = s.hardcover_files or {}
    local books = self:allCachedBooks()
    local by_id = {}
    for _i, b in ipairs(books) do by_id[tostring(b.id)] = b end
    for id, p in pairs(s.hardcover_files) do
        if p == path and by_id[id] then return by_id[id] end
    end
    local meta
    if type(props) == "table" then meta = { title = props.title, authors = props.authors } end
    local candidates = {}
    for _i, b in ipairs(books) do
        -- Skip books the user detached or attached to another file.
        local rec = s.hardcover_files[tostring(b.id)]
        if rec == nil or (rec and not fileExists(rec)) then candidates[#candidates + 1] = b end
    end
    local book = Hardcover.findBook(Hardcover.fileEntry(path, meta), candidates)
    if book then
        s.hardcover_files[tostring(book.id)] = path
        self.plugin:saveSettings()
    else
        NoMatch[path] = true
    end
    return book
end

local STATUS_NAMES = {
    [Hardcover.STATUS_READING] = _("Currently reading"),
    [Hardcover.STATUS_READ] = _("Read"),
}

function HardcoverUI:statusSyncOn()
    return self:settings().hardcover_status_sync ~= false and self.json ~= nil and self:hasToken()
end

function HardcoverUI:onBookOpened(path, props)
    if not path or not self:statusSyncOn() then return end
    local book = self:bookForFile(path, props)
    if book then self:queueStatus(book, Hardcover.STATUS_READING) end
end

function HardcoverUI:onBookFinished(path)
    if not path or not self.json or not self:hasToken() then return end
    local book = self:bookForFile(path)
    if not book then return end
    if self:statusSyncOn() then self:queueStatus(book, Hardcover.STATUS_READ) end
    if self:settings().hardcover_series_follow ~= false then self:offerNextInSeries(book) end
end

function HardcoverUI:getToggleItem(key, text)
    return {
        text = text,
        checked_func = function() return self:settings()[key] ~= false end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local s = self:settings()
            s[key] = s[key] == false
            self.plugin:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
end

-------------------------------------------------------------------------------
-- Next book in a series
-------------------------------------------------------------------------------

-- Books offered this session, so finishing (end of book, then closing it)
-- asks only once.
local offered = {}

function HardcoverUI:offerNextInSeries(book)
    if not book.series_id or not book.series_pos or offered[book.id] then return end
    offered[book.id] = true
    local key = "books:series:" .. tostring(book.series_id)
    local s = self:settings()
    local cache = self:cache()
    local books = cache[key]
    if not books then
        if not isOnline() then return end
        books = self:withLoading(_("Looking for the next book in the series…"), self:loader(key))
        if not books then return end
        cache[key] = copyWithoutPaths(books)
        self:saveCache()
    end
    local nxt = Hardcover.nextInSeries(books, book.series_pos)
    if not nxt then return end
    local path = self:localFile(nxt)
    if self.dirty then self.dirty = false self.plugin:saveSettings() end
    local ConfirmBox = require("ui/widget/confirmbox")
    if path then
        UIManager:show(ConfirmBox:new{
            text = T(_("Next in %1:\n%2\n\nIt is already on your device. Open it?"), book.series_name or "", nxt.title),
            ok_text = _("Open"),
            ok_callback = function() self:openBook(path) end,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Next in %1:\n%2\n\nDownload it in the background?"), book.series_name or "", nxt.title),
        ok_text = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                if self.plugin.queue:isRunning() then
                    UIManager:show(InfoMessage:new{ text = _("Background downloads are already running. Try again when they finish.") })
                    return
                end
                self.plugin.queue:start({ nxt }, book.series_name)
            end)
        end,
    })
end

-------------------------------------------------------------------------------
-- Duplicates
-------------------------------------------------------------------------------

--- A file on the device that looks like the book of an IRC result, or nil.
function HardcoverUI:findExisting(entry)
    local cur = self:currentBook()
    if cur and cur.path and fileExists(cur.path) then return cur.path end
    local ok, files = pcall(self.localFiles, self)
    if not ok or not files then return nil end
    local guess = Hardcover.entryBook(entry)
    local found = Hardcover.findFile(cur or guess, files)
    if found then return found end
    if cur then return Hardcover.findFile(guess, files) end
end

-------------------------------------------------------------------------------
-- Metadata and cover
-------------------------------------------------------------------------------

local function httpGetToFile(url, path)
    local ltn12 = require("ltn12")
    local http = require("socket.http")
    local has_https, https = pcall(require, "ssl.https")
    local su_ok, socketutil = pcall(require, "socketutil")
    if su_ok and socketutil.set_timeout then socketutil:set_timeout(10, 30) end
    local f = io.open(path, "wb")
    if not f then return false end
    local requester = (has_https and url:sub(1, 6) == "https:") and https.request or http.request
    local ok, r1, code = pcall(requester, { url = url, method = "GET", sink = ltn12.sink.file(f) })
    if su_ok and socketutil.reset_timeout then socketutil:reset_timeout() end
    if not ok or not r1 or tonumber(code) ~= 200 then
        os.remove(path)
        return false
    end
    return true
end

--- Give a downloaded file the Hardcover title, authors, series and
-- description, and its cover, as KOReader custom metadata (shown in the file
-- browser, book information and the cover browser). The file itself is not
-- changed.
function HardcoverUI:applyMetadata(path, book)
    local DocSettings = require("docsettings")
    local util = require("util")
    local props = {
        title = book.title,
        authors = (book.authors or ""):gsub(",%s*", "\n"),
        series = book.series_name,
        series_index = book.series_pos,
        description = book.description,
    }
    if props.authors == "" then props.authors = nil end
    local sdr = DocSettings.getSidecarDir and DocSettings:getSidecarDir(path)
    if not sdr then return end
    util.makePath(sdr)
    local LuaSettings = require("luasettings")
    local custom
    if DocSettings.openSettingsFile then
        local ok, c = pcall(DocSettings.openSettingsFile)
        if ok then custom = c end
    end
    local wrote = false
    if custom and custom.flushCustomMetadata then
        custom:saveSetting("doc_props", { title = path:match("([^/]+)%.[^.]+$") })
        custom:saveSetting("custom_props", props)
        wrote = pcall(custom.flushCustomMetadata, custom, path)
    end
    if not wrote then
        local ls = LuaSettings:open(sdr .. "/custom_metadata.lua")
        ls:saveSetting("doc_props", { title = path:match("([^/]+)%.[^.]+$") })
        ls:saveSetting("custom_props", props)
        ls:flush()
    end
    if book.cover and isOnline() then
        local ext = (book.cover:match("%.(%a+)$") or "jpg"):lower()
        if ext ~= "png" and ext ~= "jpeg" and ext ~= "webp" then ext = "jpg" end
        local tmp = self.plugin.work_dir .. "/cover." .. ext
        util.makePath(self.plugin.work_dir)
        if httpGetToFile(book.cover, tmp) then
            local done = false
            if DocSettings.flushCustomCover then
                done = pcall(DocSettings.flushCustomCover, DocSettings, path, tmp)
            end
            if not done then
                local src = io.open(tmp, "rb")
                local dst = io.open(sdr .. "/cover." .. ext, "wb")
                if src and dst then dst:write(src:read("*a")) end
                if src then src:close() end
                if dst then dst:close() end
            end
            os.remove(tmp)
        end
    end
end

-------------------------------------------------------------------------------
-- Reading progress
-------------------------------------------------------------------------------

-- Hardcover could not be reached at all: stop trying the other pending
-- updates now (each would wait for the timeout again) and keep them for
-- later.
local function unreachable(ok, res, err)
    local msg = tostring(ok and err or res or "")
    return msg:find("Could not reach Hardcover", 1, true) ~= nil
end

function HardcoverUI:onProgress(path, fraction, no_send)
    local s = self:settings()
    if s.hardcover_progress_sync == false or not self.json or not self:hasToken() then return end
    local book = self:bookForFile(path)
    if not book or not book.pages then return end
    s.hardcover_progress_sent = s.hardcover_progress_sent or {}
    s.hardcover_progress_pending = s.hardcover_progress_pending or {}
    local key = tostring(book.id)
    local last = s.hardcover_progress_sent[key]
    if last and math.abs(last - fraction) < 0.01 then return end
    s.hardcover_progress_pending[key] = { fraction = fraction, pages = book.pages, title = book.title }
    self.plugin:saveSettings()
    if not no_send then self:scheduleFlush() end
end

function HardcoverUI:flushProgress()
    local s = self:settings()
    local pending = s.hardcover_progress_pending
    if type(pending) ~= "table" or next(pending) == nil then return end
    s.hardcover_progress_sent = s.hardcover_progress_sent or {}
    local done = {}
    for key, p in pairs(pending) do
        local ok, res, err = pcall(self.client.setProgress, self.client, tonumber(key) or key,
                                   p.fraction, p.pages, os.date("%Y-%m-%d"))
        if ok and res then
            s.hardcover_progress_sent[key] = p.fraction
            done[#done + 1] = key
        elseif unreachable(ok, res, err) then
            logger.warn("ircbooks: Hardcover not reachable, progress kept for later")
            break
        else
            logger.warn("ircbooks: Hardcover progress update failed:", ok and err or res)
            p.tries = (p.tries or 0) + 1
            if p.tries >= 5 then done[#done + 1] = key end
        end
    end
    for _i, key in ipairs(done) do pending[key] = nil end
    self.plugin:saveSettings()
end

--- Remember a status to send, then send it now if online (else later, when
-- Wi-Fi comes on or on the next sync).
function HardcoverUI:queueStatus(book, status)
    local s = self:settings()
    s.hardcover_status_sent = s.hardcover_status_sent or {}
    s.hardcover_status_pending = s.hardcover_status_pending or {}
    local key = tostring(book.id)
    local sent = s.hardcover_status_sent[key]
    if sent == status or (status == Hardcover.STATUS_READING and sent == Hardcover.STATUS_READ) then return end
    local pending = s.hardcover_status_pending[key]
    if pending and pending.status == Hardcover.STATUS_READ and status == Hardcover.STATUS_READING then return end
    s.hardcover_status_pending[key] = { status = status, title = book.title }
    self.plugin:saveSettings()
    self:scheduleFlush()
end

-- One pending send for all instances, so opening, closing and finishing a
-- book in quick succession makes one round of requests, a little later,
-- when the screen has settled.
local flush_fn
function HardcoverUI:scheduleFlush(delay)
    if flush_fn then UIManager:unschedule(flush_fn) end
    flush_fn = function()
        flush_fn = nil
        self:flushStatus(true)
    end
    UIManager:scheduleIn(delay or 3, flush_fn)
end

--- Send pending reading status and progress. quick: use short timeouts
-- (an update in the background, not something the user is waiting for).
function HardcoverUI:flushStatus(quick)
    if not self.json or not self:hasToken() or not isOnline() then return end
    local s = self:settings()
    local has_status = type(s.hardcover_status_pending) == "table" and next(s.hardcover_status_pending) ~= nil
    local has_progress = type(s.hardcover_progress_pending) == "table" and next(s.hardcover_progress_pending) ~= nil
    if not has_status and not has_progress then return end
    if quick then timeouts = TIMEOUTS_QUICK end
    -- Status first: a finished book's progress should not reopen a read.
    local ok, err = pcall(function()
        if self:flushStatusOnly() ~= false then self:flushProgress() end
    end)
    timeouts = TIMEOUTS_NORMAL
    if not ok then logger.warn("ircbooks: Hardcover update failed:", err) end
end


function HardcoverUI:flushStatusOnly()
    local s = self:settings()
    local pending = s.hardcover_status_pending
    if type(pending) ~= "table" or next(pending) == nil then return end
    s.hardcover_status_sent = s.hardcover_status_sent or {}
    local done = {}
    for key, p in pairs(pending) do
        local ok, res, err = pcall(self.client.setStatus, self.client, tonumber(key) or key, p.status)
        if not (ok and res) and unreachable(ok, res, err) then
            logger.warn("ircbooks: Hardcover not reachable, status kept for later")
            for _i, k in ipairs(done) do pending[k] = nil end
            self.plugin:saveSettings()
            return false
        end
        if ok and res then
            s.hardcover_status_sent[key] = p.status
            done[#done + 1] = key
            if res == "set" then
                notify(T(_("Hardcover: “%1” marked as %2"), p.title or "", STATUS_NAMES[p.status] or ""))
            end
        else
            logger.warn("ircbooks: Hardcover status update failed:", ok and err or res)
            p.tries = (p.tries or 0) + 1
            if p.tries >= 5 then done[#done + 1] = key end
        end
    end
    for _i, key in ipairs(done) do pending[key] = nil end
    self.plugin:saveSettings()
end

--- Called by the plugin after a download. Returns true when this flow
-- handles what happens next.
function HardcoverUI:onDownloaded(path)
    local cur = self.current
    if not cur or not self.books_menu then return false end
    local book = cur.book
    local s = self:settings()
    s.hardcover_files = s.hardcover_files or {}
    s.hardcover_files[tostring(book.id)] = path
    self.plugin:saveSettings()
    book.path = path
    self:refreshBooks()
    local n = self:nextMissing(cur.index)
    local DocumentRegistry = require("document/documentregistry")
    local can_open = DocumentRegistry:hasProvider(path)
    local title = T(_("Saved “%1” to:\n%2"), book.title, path)
    if n then
        title = title .. "\n\n" .. T(_("Next missing book:\n%1"), self.books[n].title)
    else
        title = title .. "\n\n" .. _("This was the last missing book in the list.")
    end
    local dialog
    local row = {}
    if can_open then
        row[#row + 1] = {
            text = _("Open"),
            callback = function()
                UIManager:close(dialog)
                self:openBook(path)
            end,
        }
    end
    row[#row + 1] = {
        text = _("Cancel"),
        callback = function()
            UIManager:close(dialog)
            self.current = nil
            self.plugin:closeResults()
        end,
    }
    if n then
        row[#row + 1] = {
            text = _("Next book"),
            callback = function()
                UIManager:close(dialog)
                self:goNext(cur.index)
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "left",
        buttons = { row },
    }
    UIManager:show(dialog)
    return true
end

function HardcoverUI:openBook(path)
    self.plugin:closeResults()
    self:closeMenus()
    -- Come back to this view when the book is closed, if it is the home view.
    if self:settings().hardcover_startup then package.loaded["ircbooks.return_to_hardcover"] = true end
    self.plugin:openBook(path)
end

--- Called when a file browser starts. Opens the Hardcover view at KOReader
-- start, and again after closing a book that was opened from it.
function HardcoverUI:maybeOpenAtStart()
    if not self:settings().hardcover_startup then return end
    local first = not package.loaded["ircbooks.started"]
    local back = package.loaded["ircbooks.return_to_hardcover"]
    package.loaded["ircbooks.started"] = true
    package.loaded["ircbooks.return_to_hardcover"] = nil
    if first or back then
        UIManager:scheduleIn(0.5, function() self:openHome() end)
    end
end

function HardcoverUI:getStartupItem()
    return {
        text = _("Start KOReader in the Hardcover view"),
        checked_func = function() return self:settings().hardcover_startup end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local s = self:settings()
            s.hardcover_startup = not s.hardcover_startup
            self.plugin:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
end

return HardcoverUI
