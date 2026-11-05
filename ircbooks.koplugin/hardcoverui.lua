--[[--
Hardcover screens for the IRC book search plugin: the user's lists, the books
in a list with whether each has a file on the device, and a "next book" flow
that searches IRC for one missing book after another.
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

--- Blocking HTTPS POST using KOReader's LuaSocket/LuaSec.
local function httpPost(url, headers, body)
    local ltn12 = require("ltn12")
    local http = require("socket.http")
    local has_https, https = pcall(require, "ssl.https")
    local su_ok, socketutil = pcall(require, "socketutil")
    if su_ok and socketutil.set_timeout then socketutil:set_timeout(15, 45) end
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
    s.hardcover_cache = s.hardcover_cache or {}
    local cached = s.hardcover_cache[key]
    if cached then return cached end
    if not isOnline() then
        NetworkMgr:runWhenOnline(retry)
        return nil, nil
    end
    local data, err = self:withLoading(text, self:loader(key))
    if data then
        s.hardcover_cache[key] = copyWithoutPaths(data)
        if not s.hardcover_synced_at then s.hardcover_synced_at = os.time() end
        self.plugin:saveSettings()
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
    local old = s.hardcover_cache or {}
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
        s.hardcover_cache = fresh
        s.hardcover_synced_at = os.time()
        self.plugin:saveSettings()
    end
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
    self.local_files = Hardcover.scan(lfs, roots, 5)
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
    if not self.local_files then self:scanLocalFiles() end
    return Hardcover.findFile(book, self.local_files)
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
    self.local_files = nil
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
    table.insert(items, 1, {
        text = missing > 0 and T(_("Download missing books one by one (%1)"), missing)
                            or _("Every book in this list is on the device"),
        mandatory = T(_("%1 of %2 on device"), #books - missing, #books),
        bold = true,
        start_queue = missing > 0,
        rescan = missing == 0,
        separator = true,
    })
    if #books == 0 then
        items[#items + 1] = { text = _("This list is empty."), dim = true }
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
    if item.start_queue then
        local i = self:nextMissing(0)
        if i then self:searchBook(i) end
        return
    end
    if item.rescan then
        self.local_files = nil
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
