-- Browsable view of the Library: built from the copy of the catalog that the last sync saved
-- on the device (sync.build_catalog), so browsing never contacts the server.
-- Views: Recently added, Continue reading, All books, Folders, Series, Authors, Search.
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local sync = require("librarysync/sync")
local util = require("librarysync/util")
local httpmod = require("librarysync/http")
local shared = require("librarysync/shared")

local Browser = {}
Browser.__index = Browser

--- plugin: the LibrarySync widget (config(), checkReady(), openSettings(), syncNow(), runSync(), openFile()).
function Browser:new(plugin)
    return setmetatable({ plugin = plugin, stack = {} }, Browser)
end

function Browser:cfg()
    local cfg = self.plugin:config()
    cfg.transport, cfg.headers = httpmod.get, httpmod.auth_headers(cfg)
    return cfg
end

local function num(n) return n and (n:gsub("%.0+$", "")) or nil end

local function bookTitle(book)
    if book.series and book.series ~= "" then
        return book.series .. (book.number and (" #" .. num(book.number)) or "") .. " – " .. book.title
    end
    return book.title
end

local function lower(s) return (s or ""):lower() end

local function byTitle(a, b) return lower(a.title) < lower(b.title) end

local function bySeries(a, b)
    local sa, sb = lower(a.series), lower(b.series)
    if sa ~= sb then
        if sa == "" then return false end
        if sb == "" then return true end
        return sa < sb
    end
    local na, nb = tonumber(a.number or "") or math.huge, tonumber(b.number or "") or math.huge
    if na ~= nb then return na < nb end
    return byTitle(a, b)
end

local function sorted(list, cmp)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    table.sort(out, cmp)
    return out
end

function Browser:catalog()
    local cat = util.load_table(self.plugin:config().catalog_path)
    if cat and type(cat.books) == "table" then return cat end
end

function Browser:loadState()
    return util.load_table(self.plugin:config().state_path) or { files = {} }
end

-- Where the file is on the device, if it is.
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

--- Menu items for a list of books. folder_title: the folder being shown, if any.
function Browser:bookItems(books, folder_title)
    local cfg, state = self.plugin:config(), self:loadState()
    local items = {}
    for _i, b in ipairs(books) do
        for _j, f in ipairs(b.files or {}) do
            local item = { text = bookTitle(b), file = f, multi = #b.files > 1, folder_title = folder_title }
            item.action = function() self:openBook(item) end
            self:markItem(cfg, item, state)
            items[#items + 1] = item
        end
    end
    if #items == 0 then items[1] = { text = _("(no books)") } end
    return items
end

-- A list view: name + function building its items (rebuilt after a sync).
local function view(title, build) return { title = title, build = build } end

-- Group books by keys(book) -> list of names; returns sorted { {name, books} }.
local function groups(books, keys)
    local by, order = {}, {}
    for _i, b in ipairs(books) do
        for _j, k in ipairs(keys(b)) do
            if not by[k] then by[k] = {} order[#order + 1] = k end
            table.insert(by[k], b)
        end
    end
    table.sort(order, function(a, b) return lower(a) < lower(b) end)
    local out = {}
    for _i, k in ipairs(order) do out[#out + 1] = { name = k, books = by[k] } end
    return out
end

function Browser:groupItems(list, sort)
    local items = {}
    for _i, g in ipairs(list) do
        items[#items + 1] = {
            text = g.name, mandatory = tostring(#g.books),
            action = function()
                self:push(view(g.name, function() return self:bookItems(sorted(g.books, sort)) end))
            end,
        }
    end
    if #items == 0 then items[1] = { text = _("(none)") } end
    return items
end

function Browser:rootItems()
    local cat = self:catalog()
    local items = {
        { text = "⟳ " .. _("Sync everything now"), action = function() self.plugin:syncNow() end },
        { text = "⚙ " .. _("Settings"), action = function() self.plugin:openSettings() end },
    }
    if not cat then
        items[#items + 1] = { text = _("Nothing here yet: run a sync to fill the Library.") }
        return items, _("not synced yet")
    end
    local books = cat.books
    items[#items + 1] = { text = "⌕ " .. _("Search"), action = function() self:search() end }
    items[#items + 1] = { text = _("Recently added"), mandatory = "›", action = function()
        self:push(view(_("Recently added"), function()
            return self:bookItems(sorted(books, function(a, b)
                if a.updated ~= b.updated then return (a.updated or "") > (b.updated or "") end
                return byTitle(a, b)
            end))
        end))
    end }
    local reading = {}
    for _i, b in ipairs(books) do if cat.reading and cat.reading[b.id] then reading[#reading + 1] = b end end
    items[#items + 1] = { text = _("Continue reading"), mandatory = tostring(#reading), action = function()
        self:push(view(_("Continue reading"), function() return self:bookItems(sorted(reading, byTitle)) end))
    end }
    items[#items + 1] = { text = _("All books"), mandatory = tostring(#books), action = function()
        self:push(view(_("All books"), function() return self:bookItems(sorted(books, byTitle)) end))
    end }
    items[#items + 1] = { text = _("Folders"), mandatory = tostring(#(cat.folders or {})), action = function()
        self:push(view(_("Folders"), function() return self:folderItems(cat) end))
    end }
    local series = groups(books, function(b) return (b.series and b.series ~= "") and { b.series } or {} end)
    items[#items + 1] = { text = _("Series"), mandatory = tostring(#series), action = function()
        self:push(view(_("Series"), function() return self:groupItems(series, bySeries) end))
    end }
    local authors = groups(books, function(b) return b.authors or {} end)
    items[#items + 1] = { text = _("Authors"), mandatory = tostring(#authors), action = function()
        self:push(view(_("Authors"), function() return self:groupItems(authors, bySeries) end))
    end }
    return items, T(_("Last sync: %1"), os.date("%Y-%m-%d %H:%M", cat.synced_at or 0))
end

function Browser:folderItems(cat)
    local by = {}
    for _i, b in ipairs(cat.books) do
        for _j, f in ipairs(b.folders or {}) do
            by[f] = by[f] or {}
            table.insert(by[f], b)
        end
    end
    local items = {}
    for _i, f in ipairs(cat.folders or {}) do
        local books = by[f.name] or {}
        items[#items + 1] = { text = f.name, mandatory = tostring(#books), action = function()
            self:push(view(f.name, function()
                local list = self:bookItems(sorted(books, bySeries), f.name)
                if f.url then
                    table.insert(list, 1, { text = "⟳ " .. _("Download everything in this folder"),
                                            action = function() self:syncFolder(f.url, f.name) end })
                end
                return list
            end))
        end }
    end
    if #items == 0 then items[1] = { text = _("(no folders)") } end
    return items
end

function Browser:search()
    local cat = self:catalog()
    if not cat then return end
    local dialog
    dialog = InputDialog:new{
        title = _("Search the Library"),
        input_hint = _("title, author, series or folder"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = util.trim(dialog:getInputText() or "")
                UIManager:close(dialog)
                if q == "" then return end
                local words = {}
                for w in lower(q):gmatch("%S+") do words[#words + 1] = w end
                local hits = {}
                for _i, b in ipairs(cat.books) do
                    local hay = lower(table.concat({ b.title or "", table.concat(b.authors or {}, " "),
                        b.series or "", table.concat(b.folders or {}, " ") }, " "))
                    local all = true
                    for _j, w in ipairs(words) do if not hay:find(w, 1, true) then all = false break end end
                    if all then hits[#hits + 1] = b end
                end
                self:push(view(T(_("Search: %1"), q), function() return self:bookItems(sorted(hits, bySeries)) end))
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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

local function bookCount(items, subtitle)
    if subtitle then return subtitle end
    local n = 0
    for _i, it in ipairs(items) do if it.file then n = n + 1 end end
    return n > 0 and T(_("%1 books"), n) or nil
end

-- Open a view on top of the current one.
function Browser:push(v)
    local cur = self.stack[#self.stack]
    if cur and self.menu then
        cur.itemnumber = ((self.menu.page or 1) - 1) * (self.menu.perpage or 1) + 1
    end
    local items, subtitle = v.build()
    v.items, v.subtitle = items, bookCount(items, subtitle)
    self.stack[#self.stack + 1] = v
    self:show(v, 1)
end

--- Rebuild the view on screen from the saved catalog (after a download or a sync).
function Browser:refresh()
    local top = self.stack[#self.stack]
    if not (self.menu and top) then return end
    local n = ((self.menu.page or 1) - 1) * (self.menu.perpage or 1) + 1
    local items, subtitle = top.build()
    top.items, top.subtitle = items, bookCount(items, subtitle)
    self.menu:switchItemTable(top.title, top.items, n, nil, top.subtitle)
end
Browser.refreshMarks = Browser.refresh

function Browser:start()
    if self.menu then self:close() end
    self.stack = {}
    self:push(view(_("Library"), function() return self:rootItems() end))
end

function Browser:close()
    local m = self.menu
    self.menu = nil
    self.stack = {}
    if shared.browser == self then shared.browser = nil end
    if m then UIManager:close(m) end
end

function Browser:back()
    table.remove(self.stack)
    local top = self.stack[#self.stack]
    if not top then self:close() return end
    self:show(top, top.itemnumber)
    self:refresh()
end

function Browser:openBook(item)
    local file = item.file
    local cfg = self.plugin:config()
    local path = self:localCopy(cfg, item, self:loadState())
    if path then
        self:close()
        self.plugin:openFile(path)
        return
    end
    -- Not on the device: offer to fetch just this book (the only time browsing goes online).
    -- Into the open folder, else the book's first Library folder (the next sync copies it to
    -- its other folders), else straight into the download folder.
    local dir = item.folder_title or (file.folders or {})[1]
    UIManager:show(ConfirmBox:new{
        text = T(_("“%1” is not on the device yet. Download it now into %2?"), file.name, dir or cfg.base),
        ok_text = _("Download"),
        ok_callback = function()
            if not self.plugin:checkReady() then return end
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function()
                    local last = 0
                    Trapper:info(T(_("Downloading (tap to stop)\n%1"), file.name))
                    local ok, p, err = pcall(sync.download_one, self:cfg(), dir, file, function(n)
                        local now = os.time()
                        if now == last then return true end
                        last = now
                        return Trapper:info(T(_("Downloading (tap to stop)\n%1  %2 MB"), file.name, string.format("%.1f", n / 1048576)))
                    end)
                    Trapper:clear()
                    if not ok then p, err = nil, p end
                    if p then
                        self:refresh()
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
    local cfg = self.plugin:checkReady()
    if not cfg then return end
    cfg.only = { url = url, name = title }
    self.plugin:runSync(cfg)
end

return Browser
