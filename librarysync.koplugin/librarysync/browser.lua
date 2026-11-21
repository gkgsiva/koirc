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

--- Build menu items for a parsed feed.
function Browser:itemsFor(feed, url, title, cfg)
    local items = {}
    local in_folder = isFolderUrl(url)
    if in_folder then
        items[#items + 1] = { text = "⟳ " .. _("Download everything in this folder"),
                              action = function() self:syncFolder(url, title) end }
    end
    for _, e in ipairs(feed.entries) do
        local files = sync.book_files(cfg, url, e)
        if #files > 0 then
            for _, f in ipairs(files) do
                local dest, have = sync.local_path(cfg, in_folder and title or "Library", f)
                items[#items + 1] = {
                    text = bookTitle(f),
                    mandatory = (have and "✓ " or "") .. (#files > 1 and f.ext or ""),
                    action = function() self:openBook(f, in_folder and title or "Library") end,
                }
            end
        else
            local l = xml.link(e, "subsection")
            if l then
                local href = util.resolve(url, l.href)
                items[#items + 1] = { text = e.title, mandatory = "›",
                                      action = function() self:open(href, e.title) end }
            end
        end
    end
    local nxt = xml.link(feed, "next")
    if nxt then
        local href = util.resolve(url, nxt.href)
        items[#items + 1] = { text = "… " .. _("Load more"), action = function() self:more(href, title) end }
    end
    return items
end

function Browser:show(title, items, subtitle)
    if not self.menu then
        self.menu = Menu:new{
            title = title,
            subtitle = subtitle,
            item_table = items,
            is_borderless = true, is_popout = false, covers_fullscreen = true,
            title_bar_fm_style = true,
            width = Screen:getWidth(), height = Screen:getHeight(),
            paths = {},  -- non-empty = show the back arrow
            onMenuSelect = function(_, item) if item.action then item.action() end return true end,
            onReturn = function() self:back() end,
            close_callback = function() self.menu = nil self.stack = {} end,
        }
        UIManager:show(self.menu)
    else
        local paths = {}
        for i = 1, #self.stack - 1 do paths[i] = true end
        self.menu.paths = paths
        self.menu:switchItemTable(title, items, 1, nil, subtitle)
    end
end

function Browser:header(items)
    table.insert(items, 1, { text = "⟳ " .. _("Sync everything now"), action = function() self:close() self.plugin:syncNow() end })
    table.insert(items, 2, { text = "⚙ " .. _("Settings"), action = function() self.plugin:openSettings() end })
    return items
end

function Browser:start()
    local cfg = self.plugin:checkReady()
    if not cfg then return end
    self.stack = {}
    self:open(cfg.server .. "/opds", _("Library"))
end

function Browser:close()
    if self.menu then UIManager:close(self.menu) self.menu = nil end
    self.stack = {}
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

function Browser:open(url, title)
    local loading = InfoMessage:new{ text = _("Loading…"), timeout = 0 }
    UIManager:show(loading)
    NetworkMgr:runWhenOnline(function()
        UIManager:nextTick(function()
            local feed, cfg = self:load(url)
            UIManager:close(loading)
            if not feed then return end
            self.stack[#self.stack + 1] = { url = url, title = title }
            local items = self:itemsFor(feed, url, title, cfg)
            if #self.stack == 1 then items = self:header(items) end
            self:show(title, items, #feed.entries .. " " .. _("items"))
        end)
    end)
end

function Browser:more(url, title)
    local feed, cfg = self:load(url)
    if not feed then return end
    local items = self:itemsFor(feed, url, title, cfg)
    -- replace the trailing "Load more" with the next page
    local cur = self.menu.item_table
    table.remove(cur)
    for _, it in ipairs(items) do
        if not it.text:find("⟳", 1, true) then cur[#cur + 1] = it end
    end
    self.menu:switchItemTable(title, cur, #cur - #items + 1)
end

function Browser:back()
    table.remove(self.stack)
    local top = table.remove(self.stack)
    if not top then self:close() return end
    self:open(top.url, top.title)
end

function Browser:openBook(file, dir)
    local cfg = self:cfg()
    local dest, have = sync.local_path(cfg, dir, file)
    if have then
        self:close()
        self.plugin:openFile(dest)
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download “%1” into %2?"), file.name, dir),
        ok_text = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function()
                    local last = 0
                    local path, err = sync.download_one(cfg, dir, file, function(n)
                        local now = os.time()
                        if now == last then return true end
                        last = now
                        return Trapper:info(T(_("Downloading (tap to stop)\n%1  %2 MB"), file.name, string.format("%.1f", n / 1048576)))
                    end)
                    if path then
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Downloaded “%1”. Open it now?"), file.name),
                            ok_text = _("Open"),
                            ok_callback = function() self:close() self.plugin:openFile(path) end,
                        })
                        -- refresh the ✓ marks
                        if self.menu then self.menu:updateItems() end
                    else
                        UIManager:show(InfoMessage:new{ text = T(_("Download failed: %1"), tostring(err)) })
                    end
                end)
            end)
        end,
    })
end

function Browser:syncFolder(url, title)
    local cfg = self:cfg()
    cfg.only_url = url
    NetworkMgr:runWhenOnline(function()
        self.plugin:runSync(cfg)
    end)
end

return Browser
