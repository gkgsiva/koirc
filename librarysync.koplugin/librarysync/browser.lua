-- Browsable view of the Library server's OPDS catalog (folders, series, books)
-- with download and sync actions. Built on KOReader's Menu widget.
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local sync = require("librarysync/sync")
local xml = require("librarysync/xml")
local util = require("librarysync/util")
local httpmod = require("librarysync/http")
local shared = require("librarysync/shared")

local Browser = {}
Browser.__index = Browser

--- plugin: the LibrarySync widget (config(), openSettings(), syncNow(), openFile()).
function Browser:new(plugin)
    return setmetatable({ plugin = plugin, stack = {} }, Browser)
end

function Browser:cfg()
    local cfg = self.plugin:config()
    cfg.transport, cfg.headers = httpmod.get, httpmod.auth_headers(cfg)
    return cfg
end

local function bookTitle(file)
    if file.series then
        return file.series .. (file.number and (" #" .. file.number:gsub("%.0+$", "")) or "") .. " – " .. (file.title or file.name)
    end
    return file.title or file.name
end

-- Folder view = a feed under /opds/folders/<id>: books there belong to a local folder of that name.
local function isFolderUrl(url) return url:match("/opds/folders/%d+") ~= nil end

-- Local folders a book shown on this page belongs to: the open folder, else the book's own
-- Library folders (Recently added, Series, Authors, search...). Empty = straight in the base.
local function dirsFor(file, folder_title)
    if folder_title then return { folder_title } end
    return file.folders or {}
end

function Browser:loadState()
    local cfg = self.plugin:config()
    return util.load_table(cfg.state_path) or { files = {} }
end

-- Where the book is on the device, if it is.
function Browser:localCopy(cfg, item, state)
    if item.folder_title then
        local dest, have = sync.local_path(cfg, item.folder_title, item.file)
        if have then return dest end
    end
    return sync.find_local(cfg, item.file, state)
end

function Browser:markItem(cfg, item, state)
    local have = self:localCopy(cfg, item, state) ~= nil
    item.mandatory = (have and "✓ " or "") .. (item.multi and item.file.ext or "")
end

--- Build menu items for a parsed feed.
function Browser:itemsFor(feed, url, title, cfg)
    local items = {}
    local in_folder = isFolderUrl(url)
    local state = self:loadState()
    if in_folder then
        items[#items + 1] = { text = "⟳ " .. _("Download everything in this folder"), is_folder_sync = true,
                              action = function() self:syncFolder(url, title) end }
    end
    for _i, e in ipairs(feed.entries) do
        local files = sync.book_files(cfg, url, e)
        if #files > 0 then
            for _i, f in ipairs(files) do
                local item = { text = bookTitle(f), file = f, multi = #files > 1,
                               folder_title = in_folder and title or nil }
                item.action = function() self:openBook(item) end
                self:markItem(cfg, item, state)
                items[#items + 1] = item
            end
        else
            local l = xml.link(e, "subsection")
            if not l then
                -- any other link to a catalog feed is a way in too
                for _i, cand in ipairs(e.links) do
                    if cand.href and (cand.type or ""):find("opds-catalog", 1, true) then l = cand break end
                end
            end
            if l and l.href then
                local href = util.resolve(url, l.href)
                items[#items + 1] = { text = e.title, mandatory = "›",
                                      action = function() self:open(href, e.title) end }
            end
        end
    end
    local nxt = xml.link(feed, "next")
    if nxt and nxt.href then
        local href = util.resolve(url, nxt.href)
        items[#items + 1] = { text = "… " .. _("Load more"), is_more = true,
                              action = function() self:more(href, title) end }
    end
    return items
end

function Browser:show(top, itemnumber)
    shared.browser = self
    local paths = {}
    for i = 1, #self.stack - 1 do paths[i] = true end
    if not self.menu then
        self.menu = Menu:new{
            title = top.title,
            subtitle = top.subtitle,
            item_table = top.items,
            is_borderless = true, is_popout = false, covers_fullscreen = true,
            title_bar_fm_style = true,
            width = Screen:getWidth(), height = Screen:getHeight(),
            paths = paths,  -- non-empty = show the back arrow
            onMenuSelect = function(_m, item) if item.action then item.action() end return true end,
            onReturn = function() self:back() end,
            close_callback = function()
                local m = self.menu
                self.menu = nil
                self.stack = {}
                if shared.browser == self then shared.browser = nil end
                if m then UIManager:close(m) end
            end,
        }
        UIManager:show(self.menu)
    else
        self.menu.paths = paths
        self.menu:switchItemTable(top.title, top.items, itemnumber or 1, nil, top.subtitle)
    end
end

--- Recompute the ✓ marks of the page on screen (after a download or a sync).
function Browser:refreshMarks()
    local top = self.stack[#self.stack]
    if not (self.menu and top) then return end
    local cfg, state = self.plugin:config(), self:loadState()
    for _i, item in ipairs(top.items) do
        if item.file then self:markItem(cfg, item, state) end
    end
    self.menu:updateItems()
end

function Browser:header(items)
    table.insert(items, 1, { text = "⟳ " .. _("Sync everything now"), action = function() self.plugin:syncNow() end })
    table.insert(items, 2, { text = "⚙ " .. _("Settings"), action = function() self.plugin:openSettings() end })
    return items
end

function Browser:start()
    local cfg = self.plugin:checkReady()
    if not cfg then return end
    if self.menu then self:close() end
    self.stack = {}
    self:open(cfg.server .. "/opds", _("Library"))
end

function Browser:close()
    local m = self.menu
    self.menu = nil
    self.stack = {}
    if shared.browser == self then shared.browser = nil end
    if m then UIManager:close(m) end
end

function Browser:load(url)
    local cfg = self:cfg()
    local feed, err = sync.fetch_feed(cfg, url)
    if not feed then
        UIManager:show(InfoMessage:new{ text = T(_("Could not load the catalog: %1"), tostring(err)) })
        return nil
    end
    return feed, cfg
end

-- Fetch url with a "Loading…" message, then call fn(feed, cfg).
function Browser:fetch(url, fn)
    if self.busy then return end
    local token = {}
    self.busy = token
    NetworkMgr:runWhenOnline(function()
        local loading = InfoMessage:new{ text = _("Loading…"), timeout = 0 }
        UIManager:show(loading)
        UIManager:forceRePaint()
        UIManager:nextTick(function()
            local ok, feed, cfg = pcall(self.load, self, url)
            UIManager:close(loading)
            self.busy = false
            if not ok then
                UIManager:show(InfoMessage:new{ text = T(_("Could not load the catalog: %1"), tostring(feed)) })
                return
            end
            if feed then fn(feed, cfg) end
        end)
    end)
    -- runWhenOnline may never call back (Wi-Fi refused): do not stay busy forever
    UIManager:scheduleIn(30, function() if self.busy == token then self.busy = false end end)
end

function Browser:open(url, title)
    self:fetch(url, function(feed, cfg)
        local depth = #self.stack + 1
        local items = self:itemsFor(feed, url, title, cfg)
        if depth == 1 then items = self:header(items) end
        local top = { url = url, title = title, items = items, subtitle = T(_("%1 items"), #feed.entries) }
        if self.menu then
            -- remember the page we leave, to come back to it
            local cur = self.stack[#self.stack]
            if cur then cur.itemnumber = ((self.menu.page or 1) - 1) * (self.menu.perpage or 1) + 1 end
        end
        self.stack[depth] = top
        self:show(top, 1)
    end)
end

function Browser:more(url, title)
    local top = self.stack[#self.stack]
    if not top then return end
    self:fetch(url, function(feed, cfg)
        if self.stack[#self.stack] ~= top or not self.menu then return end
        local items = self:itemsFor(feed, url, title, cfg)
        -- replace the trailing "Load more" with the next page
        local cur = top.items
        if cur[#cur] and cur[#cur].is_more then table.remove(cur) end
        local first = #cur + 1
        for _i, it in ipairs(items) do
            if not it.is_folder_sync then cur[#cur + 1] = it end
        end
        self.menu:switchItemTable(nil, cur, first, nil, top.subtitle)
    end)
end

--- Back: show the previous page again from memory (no new request to the server).
function Browser:back()
    table.remove(self.stack)
    local top = self.stack[#self.stack]
    if not top then self:close() return end
    self:show(top, top.itemnumber)
    self:refreshMarks()
end

function Browser:openBook(item)
    local file = item.file
    local cfg = self:cfg()
    local path = self:localCopy(cfg, item, self:loadState())
    if path then
        self:close()
        self.plugin:openFile(path)
        return
    end
    -- Into the open folder, else the book's first Library folder (the next sync copies it to
    -- its other folders), else straight into the download folder.
    local dir = dirsFor(file, item.folder_title)[1]
    UIManager:show(ConfirmBox:new{
        text = T(_("Download “%1” into %2?"), file.name, dir or cfg.base),
        ok_text = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function()
                    local last = 0
                    Trapper:info(T(_("Downloading (tap to stop)\n%1"), file.name))
                    local ok, p, err = pcall(sync.download_one, cfg, dir, file, function(n)
                        local now = os.time()
                        if now == last then return true end
                        last = now
                        return Trapper:info(T(_("Downloading (tap to stop)\n%1  %2 MB"), file.name, string.format("%.1f", n / 1048576)))
                    end)
                    Trapper:clear()
                    if not ok then p, err = nil, p end
                    if p then
                        self:refreshMarks()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Downloaded “%1”. Open it now?"), file.name),
                            ok_text = _("Open"),
                            ok_callback = function() self:close() self.plugin:openFile(p) end,
                        })
                    elseif err ~= "cancelled" then
                        UIManager:show(InfoMessage:new{ text = T(_("Download failed: %1"), tostring(err)) })
                    end
                end)
            end)
        end,
    })
end

function Browser:syncFolder(url, title)
    local cfg = self:cfg()
    cfg.only = { url = url, name = title }
    self.plugin:runSync(cfg)
end

return Browser
