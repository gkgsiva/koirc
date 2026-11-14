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
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Hardcover = require("koirc/hardcover")
local Collections = require("collections")
local SyncPlan = require("koirc/syncplan")

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
    local ok, r1, code, resp_headers = pcall(requester, request)
    if su_ok and socketutil.reset_timeout then socketutil:reset_timeout() end
    if not ok then return nil, tostring(r1) end
    if not r1 then return nil, tostring(code) end
    return code, table.concat(chunks), resp_headers
end

local function clock()
    local ok, socket = pcall(require, "socket")
    if ok and socket.gettime then return socket.gettime() end
    return os.time()
end

local function sleepFor(seconds)
    if not seconds or seconds <= 0 then return end
    local ok, socket = pcall(require, "socket")
    if ok and socket.sleep then return socket.sleep(seconds) end
    local fok, ffiutil = pcall(require, "ffi/util")
    if fok and ffiutil.usleep then ffiutil.usleep(math.floor(seconds * 1e6)) end
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

--- What to say when Hardcover is rate limiting us.
local function busyText(minutes)
    if minutes then
        return T(_("Hardcover is busy right now (too many requests), so part of your library was not refreshed yet.\n\nThe rest will sync by itself in about %1 min. Everything already saved still works."), minutes)
    end
    return _("Hardcover is busy right now (too many requests). Try “Sync with Hardcover” again in a few minutes. Everything already saved still works.")
end

local HardcoverUI = {}
HardcoverUI.__index = HardcoverUI
HardcoverUI.busyText = busyText

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
        -- Space requests out and wait when Hardcover asks us to.
        sleep = sleepFor,
        now = clock,
        max_wait = 10,
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

--- Other data kept in the same file as the Hardcover data.
function HardcoverUI:storeValue(key)
    self:cache()
    return Store.file and Store.file:readSetting(key)
end

function HardcoverUI:setStoreValue(key, value)
    self:cache()
    if not Store.file then return end
    Store.file:saveSetting(key, value)
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
    local ok, a, b, c = pcall(fn)
    UIManager:close(msg)
    if not ok then
        logger.err("ircbooks: Hardcover request failed:", a)
        return nil, tostring(a)
    end
    return a, b, c
end

function HardcoverUI:makeMenu(opts)
    local menu
    menu = require("uiprefs").cover(Menu:new(require("uiprefs").apply(self:settings(), {
        title = opts.title or "",
        item_table = opts.items or {},
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        -- Long titles wrap over several lines (see uiprefs for the size).
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
    })))
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
    -- New releases are worked out during a sync, not loaded.
    if kind == "new" then return nil end
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
    if Hardcover.isBusy(err) then err = busyText() end
    if data then
        cache[key] = copyWithoutPaths(data)
        self:saveCache()
        -- The next sync need not load it again.
        local meta = self:storeValue("sync_meta") or {}
        meta[key] = { at = os.time(), fp = SyncPlan.fingerprints(cache.lists, cache.series)[key] }
        self:setStoreValue("sync_meta", meta)
        if not s.hardcover_synced_at then
            s.hardcover_synced_at = os.time()
            self.plugin:saveSettings()
        end
    end
    return data, err
end

-- Followed series checked for new releases on each sync.
local SYNC_MAX_SERIES = 30
-- Sync by itself when Wi-Fi comes on and the last sync is older than this.
local AUTO_SYNC_AGE = 6 * 3600
-- Give up on a background sync that takes longer than this.
local BG_SYNC_TIMEOUT = 600
-- How often the scheduled sync looks whether it may run.
local SCHEDULE_CHECK = 30 * 60
-- Want to read books queued per scheduled run, and how long a book that
-- was not found is left alone.
local WISHLIST_MAX = 5
local WISHLIST_RETRY_AFTER = 3 * 86400
-- When Hardcover is busy, retry the rest of a sync in the background (at
-- most this many times in a row).
local BUSY_RETRIES = 3

--- Load everything a sync needs from Hardcover. run(text, fn) runs one
-- request (showing text in the foreground). Data that has not changed
-- since the last sync (see koirc/syncplan.lua) is kept rather than loaded
-- again, and lists and series are loaded several per request.
-- Returns fresh (cache keys to data), failed (first error, if any), extra
-- (followed authors and their recent books, for new releases), info:
-- {busy = {wait} when Hardcover is rate limiting, meta (when each key was
-- loaded), goals, loaded, kept}. Has no other side effects, so it can run
-- in a background process.
function HardcoverUI:gatherSync(old, run, meta, now)
    local s = self:settings()
    local c = self.client
    now = now or os.time()
    local new_meta = {}
    for k, v in pairs(type(meta) == "table" and meta or {}) do new_meta[k] = v end
    meta = new_meta
    local info = { meta = meta, loaded = 0, kept = 0 }
    local fresh, failed, extra = {}, nil, nil
    local step, total = 0, 2
    local function call(fn)
        step = step + 1
        local data, err, wait = run(T(_("Syncing with Hardcover… (%1 of %2)"), step, math.max(step, total)), fn)
        if not data and Hardcover.isBusy(err) then
            info.busy = info.busy or { wait = tonumber(wait) or 60 }
        end
        if data then info.loaded = info.loaded + 1 end
        return data, err
    end

    local lists, err = call(self:loader("lists"))
    if not lists then return nil, err or _("Could not reach Hardcover."), nil, info end
    fresh.lists = copyWithoutPaths(lists)
    meta.lists = { at = now }
    local series
    series, err = call(self:loader("series"))
    if series then
        fresh.series = copyWithoutPaths(series)
        meta.series = { at = now }
    else
        failed = failed or err
        fresh.series = old.series
    end

    -- What to have saved: lists and series opened before, every list and
    -- tracked series when they are mirrored as collections, followed
    -- series (new releases) and the Want to read shelf (wishlist).
    local keys, have, followed = {}, {}, {}
    local list_ids = {}
    for _i, l in ipairs(fresh.lists.lists or {}) do list_ids["books:list:" .. tostring(l.id)] = true end
    local function want(key)
        if have[key] or not self:loader(key) then return end
        -- A list deleted on Hardcover is dropped.
        if SyncPlan.kind(key) == "list" and not list_ids[key] then return end
        have[key] = true
        keys[#keys + 1] = key
    end
    for key in pairs(old) do
        if key ~= "lists" and key ~= "series" and type(key) == "string" then want(key) end
    end
    if Collections.enabled(s) then
        for _k, k in ipairs(Collections.syncKeys({ lists = fresh.lists, series = fresh.series })) do want(k) end
    end
    if s.hardcover_new_releases ~= false then
        local following = (type(fresh.series) == "table" and fresh.series.following) or {}
        for i = 1, math.min(#following, SYNC_MAX_SERIES) do
            local key = "books:series:" .. tostring(following[i].id)
            followed[key] = true
            want(key)
        end
    end
    if s.wishlist_auto_download then want("books:status:" .. tostring(Hardcover.STATUS_WANT_TO_READ)) end
    table.sort(keys)

    local fps = SyncPlan.fingerprints(fresh.lists, fresh.series)
    local todo, keep = SyncPlan.plan(keys, old, meta, fps, now, followed)
    for _i, key in ipairs(keep) do fresh[key] = old[key] end
    info.kept = #keep
    local batches = SyncPlan.batches(todo)
    total = step + #batches
    for _i, b in ipairs(batches) do
        if info.busy then
            -- Hardcover asked us to slow down: keep the saved copies of the
            -- rest; a later sync loads them.
            for _j, key in ipairs(b.keys) do fresh[key] = old[key] end
        else
            local res, berr
            if b.kind == "list" then
                res, berr = call(function() return c:getListBooksMany(b.ids) end)
            elseif b.kind == "series" then
                res, berr = call(function() return c:getSeriesBooksMany(b.ids) end)
            else
                local data, derr = call(self:loader(b.keys[1]))
                if data then res = { [b.ids[1]] = data } else berr = derr end
            end
            for j, key in ipairs(b.keys) do
                local data = res and res[b.ids[j]]
                if data then
                    fresh[key] = copyWithoutPaths(data)
                    meta[key] = { at = now, fp = fps[key] }
                else
                    fresh[key] = old[key] -- keep the old copy
                end
            end
            if not res then failed = failed or berr end
        end
    end

    if s.hardcover_new_releases ~= false and not info.busy and SyncPlan.due(meta, "authors", SyncPlan.EXTRA_MAX_AGE, now) then
        extra = run(_("Looking for new releases…"), function()
            local authors, aerr, wait = c:getFollowedAuthors()
            if not authors then return nil, aerr, wait end
            if #authors == 0 then return { authors = {}, books = {} } end
            local ids = {}
            for _i, a in ipairs(authors) do ids[#ids + 1] = a.id end
            local books, berr, bwait = c:getAuthorBooks(ids, os.date("%Y-%m-%d", now - 365 * 86400))
            if not books then return nil, berr, bwait end
            return { authors = authors, books = books }
        end)
        if extra then meta.authors = { at = now } end
    end
    if s.reading_goal_hardcover ~= false and not info.busy and SyncPlan.due(meta, "goals", SyncPlan.GOALS_MAX_AGE, now) then
        local goals = run(_("Loading reading goals…"), function() return c:getGoals() end)
        if goals then
            info.goals = goals
            meta.goals = { at = now }
        end
    end
    return fresh, failed, extra, info
end

--- Save what a sync loaded. Returns how many new releases were found.
-- quiet: a background sync, so don't scan the device for files now.
function HardcoverUI:applySync(fresh, old, extra, quiet, info)
    local s = self:settings()
    local new_count
    if s.hardcover_new_releases ~= false then
        local ok, n = pcall(function() return self:checkNewReleases(fresh, old, extra) end)
        if ok then new_count = n else logger.warn("ircbooks: new release check failed:", n) end
    end
    self:setCache(fresh)
    if type(info) == "table" then
        if type(info.meta) == "table" then self:setStoreValue("sync_meta", info.meta) end
        if type(info.goals) == "table" then self:setStoreValue("goals", { at = os.time(), goals = info.goals }) end
    end
    s.hardcover_synced_at = os.time()
    self.plugin:saveSettings()
    if not quiet then pcall(function() self:autoAttachAll() end) end
    self:forgetFiles()
    Collections.mirrorSoon(self)
    return new_count
end

-- Retries planned after Hardcover was busy.
local busy_retry = { count = 0, fn = nil }

--- Hardcover was busy: finish the sync in the background a bit later.
-- Returns the minutes until then, or nil when no more retries are left.
function HardcoverUI:retryWhenNotBusy(wait)
    if busy_retry.count >= BUSY_RETRIES then return nil end
    busy_retry.count = busy_retry.count + 1
    local delay = math.max(90, math.min(1800, (tonumber(wait) or 60) + 15)) * busy_retry.count
    if busy_retry.fn then UIManager:unschedule(busy_retry.fn) end
    busy_retry.fn = function()
        busy_retry.fn = nil
        if not self:backgroundSync() then logger.info("ircbooks: retry after busy Hardcover not started") end
    end
    UIManager:scheduleIn(delay, busy_retry.fn)
    logger.info("ircbooks: Hardcover busy, finishing the sync in", delay, "s")
    return math.ceil(delay / 60)
end


--- Reload everything saved on the device from Hardcover.
function HardcoverUI:sync()
    if not isOnline() then
        NetworkMgr:runWhenOnline(function() self:sync() end)
        return
    end
    if self:syncRunning() then
        UIManager:show(InfoMessage:new{ text = _("A sync with Hardcover is already running in the background."), timeout = 3 })
        return
    end
    local old = self:cache()
    local fresh, failed, extra, info = self:gatherSync(old, function(text, fn) return self:withLoading(text, fn) end,
                                                       self:storeValue("sync_meta"))
    local new_count
    if fresh then
        busy_retry.count = info and info.busy and busy_retry.count or 0
        new_count = self:applySync(fresh, old, extra, false, info)
    end
    self:flushStatus()
    self:reopenMenus()
    if info and info.busy then
        UIManager:show(InfoMessage:new{ text = busyText(self:retryWhenNotBusy(info.busy.wait)) })
    elseif failed then
        UIManager:show(InfoMessage:new{ text = T(_("Some items could not be synced:\n%1"), tostring(failed)) })
    elseif new_count and new_count > 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Synced with Hardcover.\n\n%1 new books in series and by authors you follow. See “New releases”."), new_count),
        })
    else
        UIManager:show(InfoMessage:new{ text = _("Synced with Hardcover."), timeout = 2 })
    end
    self:afterSync()
end

--- Show the open Hardcover screens again with the latest saved data.
function HardcoverUI:reopenMenus()
    if not self.lists_menu and not self.books_menu and not self.series_menu then return end
    local reopen = self.books_menu and self.source
    local series_open = self.series_menu ~= nil
    self:closeMenus()
    if self:showLists() then
        if series_open then self:showSeries() end
        if reopen then self:showBooks(reopen) end
    end
end

-- One background sync at a time for the whole session.
local bg_sync = nil

function HardcoverUI:syncRunning()
    return bg_sync ~= nil
end

--- Sync in a separate process, so the screen never waits for Hardcover.
-- The result is saved when it is ready, and open screens are refreshed.
-- Returns true when a background sync was started.
function HardcoverUI:backgroundSync()
    if bg_sync or not self.json or not self:hasToken() or not isOnline() then return false end
    local ok, ffiutil = pcall(require, "ffi/util")
    if not ok or not ffiutil.runInSubProcess or not ffiutil.readAllFromFD then return false end
    local old = self:cache()
    local meta = self:storeValue("sync_meta")
    local json = self.json
    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local result
        -- Nobody waits on this process, so it may wait longer for Hardcover.
        self.client.max_wait = 60
        local gok, err = pcall(function()
            local fresh, failed, extra, info = self:gatherSync(old, function(_text, fn)
                local fok, a, b, c = pcall(fn)
                if not fok then return nil, tostring(a) end
                return a, b, c
            end, meta)
            result = json.encode({ fresh = fresh or false, failed = failed or false, extra = extra or false, info = info or false })
        end)
        if not gok then result = json.encode({ fresh = false, failed = tostring(err) }) end
        ffiutil.writeToFD(child_fd, result, true)
    end, true)
    if not pid then return false end
    bg_sync = { pid = pid, started = os.time() }
    logger.info("ircbooks: background Hardcover sync started")
    local function poll()
        if not bg_sync or bg_sync.pid ~= pid then return end
        local ready = ffiutil.getNonBlockingReadSize and ffiutil.getNonBlockingReadSize(fd) > 0
        local done = ffiutil.isSubProcessDone(pid)
        if not ready and not done then
            if os.time() - bg_sync.started > BG_SYNC_TIMEOUT then
                logger.warn("ircbooks: background Hardcover sync took too long, stopped")
                pcall(ffiutil.terminateSubProcess, pid)
                pcall(ffiutil.readAllFromFD, fd)
                bg_sync = nil
                return
            end
            UIManager:scheduleIn(1, poll)
            return
        end
        -- The child writes its answer only at the end, so this read is short.
        local data = ffiutil.readAllFromFD(fd)
        bg_sync = nil
        local dok, res = pcall(json.decode, data or "")
        local info = dok and type(res) == "table" and type(res.info) == "table" and res.info or nil
        if not dok or type(res) ~= "table" or type(res.fresh) ~= "table" then
            logger.warn("ircbooks: background Hardcover sync failed:", dok and type(res) == "table" and res.failed or data)
            if info and info.busy then self:retryWhenNotBusy(info.busy.wait) end
            return
        end
        if type(res.failed) == "string" then logger.warn("ircbooks: background sync: some items failed:", res.failed) end
        local extra = type(res.extra) == "table" and res.extra or nil
        local n = self:applySync(res.fresh, old, extra, true, info)
        self:reopenMenus()
        if info and info.busy then
            local minutes = self:retryWhenNotBusy(info.busy.wait)
            if minutes then notify(T(_("Hardcover is busy; the rest syncs in about %1 min"), minutes)) end
        else
            busy_retry.count = 0
        end
        if n and n > 0 then
            notify(T(_("Hardcover: %1 new releases in series and authors you follow"), n))
        end
        logger.info("ircbooks: background Hardcover sync done")
        self:afterSync()
    end
    UIManager:scheduleIn(1, poll)
    return true
end

--- Is the device charging? nil when it can't tell.
local function isCharging()
    local ok, res = pcall(function()
        local p = Device:getPowerDevice()
        if not p then return nil end
        if p.isCharging then
            if p:isCharging() then return true end
        end
        if p.isCharged and p:isCharged() then return true end
        return false
    end)
    if not ok then return nil end
    return res
end
HardcoverUI.isCharging = isCharging

--- May an automatic sync run now? Only on Wi-Fi that is already on, and,
-- with "only while charging", while the device charges.
function HardcoverUI:autoSyncAllowed()
    local s = self:settings()
    if s.hardcover_auto_sync == false then return false end
    if not isOnline() then return false end
    if s.hardcover_sync_when == "charging" and isCharging() ~= true then return false end
    return true
end

--- Sync in the background when the saved copy is old (Wi-Fi just came on,
-- KOReader started, or the scheduled check).
function HardcoverUI:maybeBackgroundSync()
    local s = self:settings()
    if not self:autoSyncAllowed() then return end
    local age = tonumber(s.hardcover_sync_hours) and tonumber(s.hardcover_sync_hours) * 3600 or AUTO_SYNC_AGE
    if os.time() - (tonumber(s.hardcover_synced_at) or 0) < age then
        self:afterSync(true)
        return
    end
    self:backgroundSync()
end

-- The scheduled check, one for the whole session.
local schedule = { fn = nil }

--- Check every half hour whether the scheduled sync may run (Wi-Fi on and,
-- if chosen, charging). Nothing is sent when the saved copy is recent.
function HardcoverUI:startSchedule()
    if schedule.fn then UIManager:unschedule(schedule.fn) end
    schedule.fn = function()
        schedule.fn = nil
        local plugin = self.plugin
        local hc = (plugin.sharedHardcover and plugin:sharedHardcover()) or self
        pcall(function() hc:maybeBackgroundSync() end)
        hc:startSchedule()
    end
    UIManager:scheduleIn(SCHEDULE_CHECK, schedule.fn)
end

--- After a sync (or a scheduled check with nothing to sync): download
-- missing Want to read books in the background, when that is turned on.
-- scheduled: called from the scheduled check, so only when allowed.
function HardcoverUI:afterSync(scheduled)
    local s = self:settings()
    if not s.wishlist_auto_download then return end
    if scheduled and not self:autoSyncAllowed() then return end
    if s.hardcover_sync_when == "charging" and isCharging() ~= true then return end
    local q = self.plugin.queue
    if not q or q:isRunning() or q:isPaused() then return end
    local books = self:cache()["books:status:" .. tostring(Hardcover.STATUS_WANT_TO_READ)]
    if type(books) ~= "table" then return end
    self:localFiles()
    local tried = self:storeValue("wishlist_tried") or {}
    local now = os.time()
    local pick = {}
    for _i, b in ipairs(books) do
        local id = tostring(b.id)
        if not self:localFile(b) and now - (tonumber(tried[id]) or 0) > WISHLIST_RETRY_AFTER then
            pick[#pick + 1] = b
            tried[id] = now
            if #pick >= WISHLIST_MAX then break end
        end
    end
    if #pick == 0 then return end
    self:setStoreValue("wishlist_tried", tried)
    logger.info("ircbooks: wishlist: queueing", #pick, "books")
    q:start(pick, _("Want to read"))
end

--- "5 min ago", "3 h ago", "2 days ago".
local function ago(t)
    local d = os.time() - (tonumber(t) or 0)
    if d < 90 then return _("just now") end
    if d < 3600 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 86400 * 2 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return T(_("%1 days ago"), math.floor(d / 86400))
end
HardcoverUI.ago = ago

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
        mandatory = synced and T(_("synced %1"), ago(synced)) or _("never synced"),
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
        text = _("Complete your series"),
        mandatory = _("missing volumes"),
        open_completion = true,
    }}
    local new = self:cache()["books:new:all"]
    if type(new) == "table" and #new > 0 then
        items[#items + 1] = {
            text = _("New releases"),
            mandatory = T(_("%1 new"), #new),
            bold = true,
            source = { kind = "new", id = "all", name = _("New releases") },
        }
    end
    for _i, sh in ipairs(self:shelves()) do
        items[#items + 1] = {
            text = sh.name,
            mandatory = _("shelf"),
            source = { kind = "status", id = sh.id, name = sh.name },
        }
    end
    items[#items].separator = true
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
    -- Saved screens work without Wi-Fi; say so.
    if not isOnline() then title = T(_("%1 · offline"), title) end
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
            elseif item.open_completion then
                self:showSeriesCompletion()
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
    items[1] = { text = _("Complete your series (missing volumes)…"), open_completion = true, bold = true, separator = true }
    add(res.following, _("following"))
    add(res.started, _("started"))
    if #items == 1 then
        items[1] = { text = _("Follow a series on Hardcover's Series Tracker to see it here."), dim = true }
    end
    if self.series_menu then UIManager:close(self.series_menu) end
    local menu
    menu = self:makeMenu{
        title = _("Series tracker"),
        items = items,
        on_select = function(item)
            if item.open_completion then self:showSeriesCompletion()
            elseif item.source then self:showBooks(item.source) end
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
    Collections.mirrorSoon(self, 0.5)
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
        if book.why then
            info[#info + 1] = book.release_date and T(_("%1, %2"), book.why, book.release_date) or book.why
        end
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
    elseif missing > 0 and self.source.kind == "series" then
        -- Series completion: every missing volume in one tap.
        bg = { text = T(_("Download all %1 missing volumes in the background"), missing), queue_missing = true, bold = true }
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
    if self.source.kind == "new" then
        items[#items + 1] = { text = _("Clear new releases"), clear_new = true, separator = true }
    end
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
    if item.queue_missing then
        local list = {}
        for _i, b in ipairs(self.books or {}) do
            if not b.path then list[#list + 1] = b end
        end
        self:queueBooks(list, self.source.name)
        return
    end
    if item.refresh_files then
        self:refreshAttachments()
        return
    end
    if item.clear_new then
        local cache = self:cache()
        cache["books:new:all"] = nil
        self:saveCache()
        if self.books_menu then UIManager:close(self.books_menu) self.books_menu = nil end
        if self.lists_menu then self:showLists() end
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
    Collections.mirrorSoon(self)
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

--- "320 pages · ★ 4.2" for a book dialog, or nil.
local function bookFacts(book)
    local f = {}
    if book.pages then f[#f + 1] = T(_("%1 pages"), book.pages) end
    if tonumber(book.rating) and book.rating > 0 then f[#f + 1] = string.format("★ %.1f", book.rating) end
    if #f == 0 then return nil end
    return table.concat(f, " · ")
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
            { button(_("Move to shelf…"), function() self:showShelfPicker(book) end),
              button(_("Rate and review…"), function() self:showRatingDialog(book) end) },
            { button(_("Preview"), function() self:showPreview(book) end),
              button(_("Close"), function() end) },
        }
    else
        buttons = {
            { button(_("Attach a file I have…"), function() self:attachFile(book) end),
              button(_("Download from IRC"), function() self:searchBook(i) end) },
            { button(_("Preview"), function()
                  self:showPreview(book, {{ { text = _("Download from IRC"), callback = function() self:searchBook(i) end } }})
              end),
              button(_("Move to shelf…"), function() self:showShelfPicker(book) end) },
            { button(_("Close"), function() end) },
        }
    end
    dialog = ButtonDialog:new{
        title = (book.path and T(_("%1\n\nOn device:\n%2"), book.title, book.path)
                            or T(_("%1\n\nNo file on the device yet."), book.title))
                .. (bookFacts(book) and ("\n" .. bookFacts(book)) or ""),
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
                local name = self.source.name
                require("storage").guard(self.plugin, nil, function()
                    NetworkMgr:runWhenOnline(function()
                        self.plugin.queue:start(list, name)
                        self:refreshBooks()
                    end)
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
    Collections.mirrorSoon(self)
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
end

-------------------------------------------------------------------------------
-- Reading status on Hardcover
-------------------------------------------------------------------------------

function HardcoverUI:getCollectionsItem()
    return Collections.getSettingsItem(self)
end

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
    [Hardcover.STATUS_WANT_TO_READ] = _("Want to read"),
    [Hardcover.STATUS_READING] = _("Currently reading"),
    [Hardcover.STATUS_READ] = _("Read"),
    [Hardcover.STATUS_PAUSED] = _("Paused"),
    [Hardcover.STATUS_DNF] = _("Did not finish"),
}
HardcoverUI.STATUS_NAMES = STATUS_NAMES

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
    local function after()
        if self:settings().hardcover_series_follow ~= false then self:offerNextInSeries(book) end
    end
    if not self:askRating(book, after) then after() end
end

--- Settings → Automatic sync with Hardcover.
function HardcoverUI:getAutoSyncItem()
    local s = function() return self:settings() end
    local function radio(text, fn, check)
        return {
            text = text, radio = true, keep_menu_open = true,
            checked_func = check,
            callback = function(tm)
                fn()
                self.plugin:saveSettings()
                if tm then tm:updateItems() end
            end,
        }
    end
    local hours = { 3, 6, 12, 24 }
    local hour_items = {}
    for i, h in ipairs(hours) do
        hour_items[i] = radio(T(_("Every %1 hours"), h), function() s().hardcover_sync_hours = h end,
            function() return (tonumber(s().hardcover_sync_hours) or 6) == h end)
    end
    return {
        text_func = function()
            local st = s()
            if st.hardcover_auto_sync == false then return _("Automatic Hardcover sync: off") end
            if st.hardcover_sync_when == "charging" then return _("Automatic Hardcover sync: on Wi-Fi while charging") end
            return _("Automatic Hardcover sync: on Wi-Fi")
        end,
        sub_item_table = {
            radio(_("Off"), function() s().hardcover_auto_sync = false end,
                function() return s().hardcover_auto_sync == false end),
            radio(_("When Wi-Fi is on"), function()
                s().hardcover_auto_sync = true
                s().hardcover_sync_when = "wifi"
            end, function() return s().hardcover_auto_sync ~= false and s().hardcover_sync_when ~= "charging" end),
            radio(_("Only on Wi-Fi while charging"), function()
                s().hardcover_auto_sync = true
                s().hardcover_sync_when = "charging"
            end, function() return s().hardcover_auto_sync ~= false and s().hardcover_sync_when == "charging" end),
            {
                text_func = function() return T(_("How often: every %1 hours"), tonumber(s().hardcover_sync_hours) or 6) end,
                sub_item_table = hour_items,
                separator = true,
            },
            {
                text = _("Download missing “Want to read” books after a sync"),
                help_text = _("After an automatic sync, up to 5 books from your Want to read shelf that are not on the device are downloaded in the background. A book that was not found is tried again after 3 days. With “only while charging”, this also waits for the charger."),
                checked_func = function() return s().wishlist_auto_download == true end,
                keep_menu_open = true,
                callback = function(tm)
                    s().wishlist_auto_download = not s().wishlist_auto_download
                    self.plugin:saveSettings()
                    if tm then tm:updateItems() end
                end,
            },
            {
                text = _("Wi-Fi is never turned on for this; it runs only when Wi-Fi is already on. Unchanged lists are not loaded again."),
                enabled_func = function() return false end,
            },
        },
    }
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
            require("storage").guard(self.plugin, nil, function() NetworkMgr:runWhenOnline(function()
                if self.plugin.queue:isRunning() then
                    UIManager:show(InfoMessage:new{ text = _("Background downloads are already running. Try again when they finish.") })
                    return
                end
                self.plugin.queue:start({ nxt }, book.series_name)
            end) end)
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
-- opts.no_cover: keep the cover (when only the tags change).
function HardcoverUI:applyMetadata(path, book, opts)
    opts = opts or {}
    local DocSettings = require("docsettings")
    local util = require("util")
    local props = {
        title = book.title,
        authors = (book.authors or ""):gsub(",%s*", "\n"),
        series = book.series_name,
        series_index = book.series_pos,
        description = book.description,
    }
    -- Genres, lists and shelves as keywords: shown in Book information and
    -- found by KOReader's file search when it searches book metadata.
    if self:tagsOn() then
        if not opts.no_cover then pcall(self.loadGenres, self, { book }) end
        local tags = self:tagsFor(book)
        if #tags > 0 then props.keywords = table.concat(tags, "\n") end
    end
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
    if book.cover and not opts.no_cover and isOnline() then
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
    return msg:find("Could not reach Hardcover", 1, true) ~= nil or Hardcover.isBusy(msg)
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
-- force: the user picked this shelf, so send it even when it moves a Read
-- book back, or repeats what was sent before (it may have changed on the
-- website since).
function HardcoverUI:queueStatus(book, status, force)
    local s = self:settings()
    s.hardcover_status_sent = s.hardcover_status_sent or {}
    s.hardcover_status_pending = s.hardcover_status_pending or {}
    local key = tostring(book.id)
    local sent = s.hardcover_status_sent[key]
    local pending = s.hardcover_status_pending[key]
    if not force then
        if sent == status or (status == Hardcover.STATUS_READING and sent == Hardcover.STATUS_READ) then return end
        if pending and pending.status == Hardcover.STATUS_READ and status == Hardcover.STATUS_READING then return end
        -- Opening a book the user gave up on is not "reading" it again
        -- (opening a paused one is: that resumes it).
        if status == Hardcover.STATUS_READING and sent == Hardcover.STATUS_DNF then return end
    end
    s.hardcover_status_pending[key] = { status = status, title = book.title, force = force or nil }
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
    local has_rating = type(s.hardcover_rating_pending) == "table" and next(s.hardcover_rating_pending) ~= nil
    if not has_status and not has_progress and not has_rating then return end
    local max_wait = self.client.max_wait
    if quick then
        timeouts = TIMEOUTS_QUICK
        -- Don't hold the screen waiting for a busy Hardcover; try later.
        self.client.max_wait = 2
    end
    -- Status first: a finished book's progress should not reopen a read.
    local ok, err = pcall(function()
        if self:flushStatusOnly() ~= false then
            self:flushProgress()
            -- After the status: rating a book needs it on a shelf.
            self:flushRatings()
        end
    end)
    timeouts = TIMEOUTS_NORMAL
    self.client.max_wait = max_wait
    if not ok then logger.warn("ircbooks: Hardcover update failed:", err) end
end


function HardcoverUI:flushStatusOnly()
    local s = self:settings()
    local pending = s.hardcover_status_pending
    if type(pending) ~= "table" or next(pending) == nil then return end
    s.hardcover_status_sent = s.hardcover_status_sent or {}
    local done = {}
    for key, p in pairs(pending) do
        local ok, res, err = pcall(self.client.setStatus, self.client, tonumber(key) or key, p.status, p.force)
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
    Collections.mirrorSoon(self)
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

-------------------------------------------------------------------------------
-- Adding a downloaded book to Hardcover
-------------------------------------------------------------------------------

--- Find a downloaded book on Hardcover (guess: {title, author}), then put
-- it on a shelf or in a list, and attach the file to it.
function HardcoverUI:addToHardcover(guess, path)
    if not self.json then return end
    if not self:hasToken() then
        self:showTokenDialog(function()
            if self:hasToken() then self:addToHardcover(guess, path) end
        end)
        return
    end
    NetworkMgr:runWhenOnline(function()
        local q = Hardcover.searchQuery(guess)
        local books, err = self:withLoading(_("Looking the book up on Hardcover…"), function()
            return self.client:searchBooks(q)
        end)
        if not books then
            UIManager:show(InfoMessage:new{ text = err or _("Could not reach Hardcover.") })
            return
        end
        if #books == 0 then
            UIManager:show(InfoMessage:new{ text = T(_("Hardcover has no book matching “%1”."), q) })
            return
        end
        -- The match that fits title and author best first.
        local entry = Hardcover.fileEntry(path, { title = guess.title, authors = guess.author })
        table.sort(books, function(a, b)
            local ma, mb = Hardcover.matches(a, entry), Hardcover.matches(b, entry)
            if ma ~= mb then return ma end
            return false
        end)
        local dialog
        local buttons = {}
        for i, b in ipairs(books) do
            if i > 6 then break end
            local label = b.title
            if b.authors and b.authors ~= "" then label = label .. " — " .. b.authors end
            if b.release_year then label = label .. " (" .. b.release_year .. ")" end
            buttons[#buttons + 1] = {{ text = label, align = "left", callback = function()
                UIManager:close(dialog)
                self:pickTarget(b, path)
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
        dialog = ButtonDialog:new{ title = _("Which book is it?"), title_align = "center", buttons = buttons }
        UIManager:show(dialog)
    end)
end

function HardcoverUI:pickTarget(book, path)
    local dialog
    local function attach(where)
        local s = self:settings()
        s.hardcover_files = s.hardcover_files or {}
        s.hardcover_files[tostring(book.id)] = path
        self.plugin:saveSettings()
        self:forgetFiles()
        notify(T(_("Added “%1” to %2"), book.title, where))
    end
    local buttons = {}
    local row = {}
    for _i, id in ipairs({ Hardcover.STATUS_WANT_TO_READ, Hardcover.STATUS_READING, Hardcover.STATUS_READ }) do
        row[#row + 1] = { text = STATUS_NAMES[id], callback = function()
            UIManager:close(dialog)
            self:moveInCache(book, id)
            self:queueStatus(book, id, true)
            attach(STATUS_NAMES[id])
        end }
    end
    buttons[1] = row
    local lists = self:cache().lists
    for _i, l in ipairs(type(lists) == "table" and lists.lists or {}) do
        buttons[#buttons + 1] = {{ text = l.name, align = "left", callback = function()
            UIManager:close(dialog)
            local ok, err = self:withLoading(T(_("Adding to “%1”…"), l.name), function()
                return self.client:addToList(l.id, book.id)
            end)
            if not ok then
                UIManager:show(InfoMessage:new{ text = err or _("Could not reach Hardcover.") })
                return
            end
            local cached = self:cache()["books:list:" .. tostring(l.id)]
            if type(cached) == "table" then
                cached[#cached + 1] = copyWithoutPaths(book)
                self:saveCache()
            end
            attach(l.name)
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title = T(_("Add “%1” to:"), book.title),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-------------------------------------------------------------------------------
-- Shelves
-------------------------------------------------------------------------------

--- Shelves shown in the lists view (Read is left out: it is usually long).
function HardcoverUI:shelves()
    return {
        { id = Hardcover.STATUS_WANT_TO_READ, name = STATUS_NAMES[Hardcover.STATUS_WANT_TO_READ] },
        { id = Hardcover.STATUS_READING, name = STATUS_NAMES[Hardcover.STATUS_READING] },
        { id = Hardcover.STATUS_PAUSED, name = STATUS_NAMES[Hardcover.STATUS_PAUSED] },
        { id = Hardcover.STATUS_DNF, name = STATUS_NAMES[Hardcover.STATUS_DNF] },
    }
end

--- Keep the shelves saved on the device in step with a move, so they are
-- right before the next sync.
function HardcoverUI:moveInCache(book, status)
    local cache = self:cache()
    for key, books in pairs(cache) do
        if key:match("^books:status:") and type(books) == "table" then
            for i = #books, 1, -1 do
                if type(books[i]) == "table" and books[i].id == book.id then table.remove(books, i) end
            end
        end
    end
    local target = cache["books:status:" .. tostring(status)]
    if type(target) == "table" then table.insert(target, 1, copyWithoutPaths(book)) end
    self:saveCache()
end

function HardcoverUI:showShelfPicker(book)
    if not self.json or not self:hasToken() then return end
    local s = self:settings()
    local sent = (s.hardcover_status_sent or {})[tostring(book.id)]
    local pending = (s.hardcover_status_pending or {})[tostring(book.id)]
    local current = pending and pending.status or sent
    local dialog
    local buttons = {}
    local list = self:shelves()
    table.insert(list, 3, { id = Hardcover.STATUS_READ, name = STATUS_NAMES[Hardcover.STATUS_READ] })
    for _i, sh in ipairs(list) do
        buttons[#buttons + 1] = {{
            text = sh.name .. (current == sh.id and "  ✓" or ""),
            callback = function()
                UIManager:close(dialog)
                self:moveToShelf(book, sh.id)
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title = T(_("Move “%1” to:"), book.title),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function HardcoverUI:moveToShelf(book, status)
    self:moveInCache(book, status)
    self:queueStatus(book, status, true)
    if not isOnline() then
        notify(T(_("“%1” will move to %2 when Wi-Fi is on."), book.title, STATUS_NAMES[status] or ""))
    end
    if self.books_menu and self.source and self.source.kind == "status" then
        self:showBooks(self.source)
    end
end

--- Run fn(book) for the Hardcover book of an open file, or explain why not.
function HardcoverUI:withBookForFile(path, props, fn)
    if not self.json or not self:hasToken() then
        UIManager:show(InfoMessage:new{ text = _("Set your Hardcover API key first (Settings → Hardcover API key).") })
        return
    end
    local book = path and self:bookForFile(path, props)
    if not book then
        UIManager:show(InfoMessage:new{
            text = _("This book is not in your Hardcover lists or shelves saved on the device.\n\nSync with Hardcover, or attach the file to the book from its list."),
        })
        return
    end
    fn(book)
end

-------------------------------------------------------------------------------
-- Rating and review
-------------------------------------------------------------------------------

-- Books asked about this session (finishing fires twice: end of book, then
-- closing it).
local asked_rating = {}

--- When a book is finished, ask for a rating unless it was rated before or
-- the user turned this off. Calls after() once the dialog is done. Returns
-- true when it asked.
function HardcoverUI:askRating(book, after)
    local s = self:settings()
    if s.hardcover_rating_prompt == false or asked_rating[book.id] then return false end
    if (s.hardcover_rated or {})[tostring(book.id)] then return false end
    asked_rating[book.id] = true
    self:showRatingDialog(book, after, true)
    return true
end

function HardcoverUI:showRatingDialog(book, after, on_finish)
    local dialog
    local done = false
    local function finish()
        if done then return end
        done = true
        if after then after() end
    end
    local stars = {}
    for n = 1, 5 do
        stars[n] = {
            text = string.rep("★", n),
            callback = function()
                UIManager:close(dialog)
                self:askReview(book, n, finish)
            end,
        }
    end
    local halves = {}
    for _i, n in ipairs({ 1.5, 2.5, 3.5, 4.5 }) do
        halves[#halves + 1] = {
            text = string.rep("★", math.floor(n)) .. "½",
            callback = function()
                UIManager:close(dialog)
                self:askReview(book, n, finish)
            end,
        }
    end
    local last = {
        { text = _("Review only…"), callback = function()
            UIManager:close(dialog)
            self:askReview(book, nil, finish)
        end },
        { text = _("Not now"), callback = function()
            UIManager:close(dialog)
            finish()
        end },
    }
    if on_finish then
        last[#last + 1] = { text = _("Don't ask again"), callback = function()
            UIManager:close(dialog)
            self:settings().hardcover_rating_prompt = false
            self.plugin:saveSettings()
            notify(_("You can turn rating prompts back on in the plugin settings."))
            finish()
        end }
    end
    dialog = ButtonDialog:new{
        title = on_finish and T(_("You finished “%1”.\n\nRate it on Hardcover?"), book.title)
                           or T(_("Rate “%1” on Hardcover"), book.title),
        title_align = "left",
        buttons = { stars, halves, last },
        tap_close_callback = finish,
    }
    UIManager:show(dialog)
end

function HardcoverUI:askReview(book, rating, done)
    local dialog
    local function send(text)
        UIManager:close(dialog)
        text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if rating or text ~= "" then self:queueRating(book, rating, text ~= "" and text or nil) end
        done()
    end
    dialog = InputDialog:new{
        title = rating and T(_("%1 for “%2”. Add a short review?"), string.rep("★", math.floor(rating)) .. (rating % 1 > 0 and "½" or ""), book.title)
                       or T(_("Review “%1”"), book.title),
        input = "",
        input_hint = _("Optional review"),
        allow_newline = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) done() end },
            { text = rating and _("Rating only") or _("Skip"), callback = function() send(nil) end },
            { text = _("Send"), is_enter_default = true, callback = function() send(dialog:getInputText()) end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function HardcoverUI:queueRating(book, rating, review)
    local s = self:settings()
    s.hardcover_rating_pending = s.hardcover_rating_pending or {}
    s.hardcover_rating_pending[tostring(book.id)] = { rating = rating, review = review, title = book.title }
    self.plugin:saveSettings()
    if isOnline() then
        self:scheduleFlush(1)
    else
        notify(T(_("Your rating of “%1” will be sent when Wi-Fi is on."), book.title))
    end
end

function HardcoverUI:flushRatings()
    local s = self:settings()
    local pending = s.hardcover_rating_pending
    if type(pending) ~= "table" or next(pending) == nil then return end
    s.hardcover_rated = s.hardcover_rated or {}
    local done = {}
    for key, p in pairs(pending) do
        local ok, res, err = pcall(self.client.setRating, self.client, tonumber(key) or key,
                                   p.rating, p.review, os.date("%Y-%m-%d"))
        if ok and res then
            s.hardcover_rated[key] = p.rating or true
            done[#done + 1] = key
            if res == "set" then
                notify(p.rating and T(_("Hardcover: rated “%1” %2★"), p.title or "", p.rating)
                                 or T(_("Hardcover: review of “%1” sent"), p.title or ""))
            end
        else
            logger.warn("ircbooks: Hardcover rating failed:", ok and err or res)
            p.tries = (p.tries or 0) + 1
            if p.tries >= 5 then done[#done + 1] = key end
        end
    end
    for _i, key in ipairs(done) do pending[key] = nil end
    self.plugin:saveSettings()
end

-------------------------------------------------------------------------------
-- New releases
-------------------------------------------------------------------------------

local MAX_SERIES_CHECKED = 30
local NEW_RELEASES_KEPT_DAYS = 60

--- During a sync: look for books that were not in followed series, or by
-- followed authors, at the last sync. Adds them to "books:new:all" in
-- fresh (with the ones found earlier that are still recent). Returns how
-- many were found now.
function HardcoverUI:checkNewReleases(fresh, old, extra)
    local s = self:settings()
    s.hardcover_known = s.hardcover_known or {}
    local groups = {}
    local following = (type(fresh.series) == "table" and fresh.series.following) or {}
    for i = 1, math.min(#following, MAX_SERIES_CHECKED) do
        local sr = following[i]
        local books = fresh["books:series:" .. tostring(sr.id)]
        if type(books) == "table" then
            groups[#groups + 1] = { key = "series:" .. tostring(sr.id), why = sr.name, books = books }
        end
    end
    local res = type(extra) == "table" and extra.authors and extra
    if res then
        for _i, a in ipairs(res.authors) do
            local mine = {}
            for _j, b in ipairs(res.books or {}) do
                if a.name and (b.authors or ""):find(a.name, 1, true) then mine[#mine + 1] = b end
            end
            groups[#groups + 1] = { key = "author:" .. tostring(a.id), why = a.name or _("followed author"), books = mine }
        end
    end
    local found = Hardcover.findNewReleases(s.hardcover_known, groups)
    local now = os.time()
    local list, seen = {}, {}
    for _i, b in ipairs(found) do
        b.found_at = now
        list[#list + 1] = b
        seen[tostring(b.id)] = true
    end
    for _i, b in ipairs(type(old["books:new:all"]) == "table" and old["books:new:all"] or {}) do
        if type(b) == "table" and not seen[tostring(b.id)] and (b.found_at or 0) > now - NEW_RELEASES_KEPT_DAYS * 86400 then
            list[#list + 1] = b
            seen[tostring(b.id)] = true
        end
    end
    if #list > 0 then fresh["books:new:all"] = copyWithoutPaths(list) end
    return #found
end

require("hcextras").install(HardcoverUI)

return HardcoverUI
