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

function Browser:queue()
    return util.load_table(self.plugin:config().queue_path) or {}
end

function Browser:markItem(cfg, item, state, queue)
    local have = self:localCopy(cfg, item, state) ~= nil
    local queued = not have and queue and queue[item.file.key]
    item.mandatory = (have and "✓ " or queued and "⏳ " or "") .. (item.multi and item.file.ext or "")
end

--- Menu items for a list of books. folder_title: the folder being shown, if any.
function Browser:bookItems(books, folder_title)
    local cfg, state, queue = self.plugin:config(), self:loadState(), self:queue()
    local items = {}
    for _i, b in ipairs(books) do
        for _j, f in ipairs(b.files or {}) do
            local item = { text = bookTitle(b), file = f, multi = #b.files > 1, folder_title = folder_title, book = b }
            item.action = function() self:openBook(item) end
            self:markItem(cfg, item, state, queue)
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
    local queue = self:queue()
    local qn = 0
    for _k in pairs(queue) do qn = qn + 1 end
    items[#items + 1] = { text = "⏳ " .. _("Read later"), mandatory = tostring(qn), action = function()
        self:push(view(_("Read later"), function() return self:queueItems() end))
    end }
    items[#items + 1] = { text = "☰ " .. _("Sync log"), action = function() self.plugin:showLog() end }
    local removed = #(util.load_table(self.plugin:config().removed_path or "") or {})
    if removed > 0 then
        items[#items + 1] = { text = "↺ " .. _("Removed books"), mandatory = tostring(removed),
                              action = function() self.plugin:showRemoved() end }
    end
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

--- The read-later queue: books to download at the next sync (marked here, also offline).
function Browser:queueItems()
    local list = {}
    for key, e in pairs(self:queue()) do
        if type(e) == "table" and e.file then
            list[#list + 1] = { key = key, e = e }
        end
    end
    table.sort(list, function(a, b) return (a.e.at or 0) < (b.e.at or 0) end)
    local cfg, state = self.plugin:config(), self:loadState()
    local items = {}
    for _i, q in ipairs(list) do
        local book = { title = q.e.title or q.e.file.name, files = { q.e.file }, folders = q.e.file.folders }
        local item = { text = book.title, file = q.e.file, folder_title = q.e.dir, book = book }
        item.action = function() self:openBook(item) end
        self:markItem(cfg, item, state, self:queue())
        items[#items + 1] = item
    end
    if #items == 0 then
        items[1] = { text = _("Nothing yet. Tap a book that is not on the device and choose Read later; the next sync downloads it.") }
    end
    return items
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
    local skip = self.plugin:config().skip_folders or {}
    for _i, f in ipairs(cat.folders or {}) do
        local books = by[f.name] or {}
        items[#items + 1] = { text = f.name,
                              mandatory = (skip[f.name] and (_("not synced") .. " · ") or "") .. tostring(#books),
                              action = function()
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

local function words(q)
    local out = {}
    for w in lower(q):gmatch("%S+") do out[#out + 1] = w end
    return out
end

--- Books of the saved catalog matching every word (title, author, series or folder).
function Browser:searchDevice(q)
    local cat = self:catalog()
    local ws, hits = words(q), {}
    for _i, b in ipairs(cat and cat.books or {}) do
        local hay = lower(table.concat({ b.title or "", table.concat(b.authors or {}, " "),
            b.series or "", table.concat(b.folders or {}, " ") }, " "))
        local all = true
        for _j, w in ipairs(ws) do if not hay:find(w, 1, true) then all = false break end end
        if all then hits[#hits + 1] = b end
    end
    return hits
end

-- Pages of server results read at most (the server sends 50 a page).
local SEARCH_PAGES = 3

--- Search the Library server itself (its /opds/search, by title, author, series, folder or tag):
-- finds books added since the last sync too. Only on request, like a single download.
function Browser:searchServer(q)
    if not self.plugin:checkReady() then return end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(T(_("Searching the Library for “%1”…"), q))
            local cfg = self:cfg()
            local hits, seen, err = {}, {}, nil
            local page, n = cfg.server .. "/opds/search?q=" .. util.url_encode(q), 0
            while page and n < SEARCH_PAGES do
                n = n + 1
                local ok, feed, ferr = pcall(sync.fetch_feed, cfg, page)
                if not ok then feed, ferr = nil, feed end
                if not feed then err = ferr break end
                for _i, e in ipairs(feed.entries) do
                    local b = sync.entry_book(cfg, page, e)
                    if b and not seen[b.id] then seen[b.id] = true hits[#hits + 1] = b end
                end
                local nxt = require("librarysync/xml").link(feed, "next")
                page = nxt and util.resolve(page, nxt.href) or nil
            end
            Trapper:clear()
            if err and #hits == 0 then
                UIManager:show(InfoMessage:new{ text = T(_("Search failed: %1"), tostring(err)) })
                return
            end
            self:push(view(T(_("Server: %1"), q), function()
                local items = self:bookItems(hits)
                if #hits == 0 then items[1] = { text = _("(nothing found on the server)") } end
                return items
            end))
        end)
    end)
end

function Browser:search()
    local dialog
    local function run(where)
        local q = util.trim(dialog:getInputText() or "")
        UIManager:close(dialog)
        if q == "" then return end
        if where == "server" then return self:searchServer(q) end
        local hits = self:searchDevice(q)
        self:push(view(T(_("Search: %1"), q), function() return self:bookItems(sorted(hits, bySeries)) end))
    end
    dialog = InputDialog:new{
        title = _("Search the Library"),
        input_hint = _("title, author, series or folder"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Server"), callback = function() run("server") end },
            { text = _("On device"), is_enter_default = true, callback = function() run("device") end },
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
            onMenuHold = function(_m, item) if item.file then self:details(item) end return true end,
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
    -- Not on the device: fetch just this book now (the only time browsing goes online), or
    -- put it on the read-later queue for the next sync (works offline).
    -- Into the open folder, else the book's first Library folder (the next sync copies it to
    -- its other folders), else straight into the download folder.
    local dir = item.folder_title or (file.folders or {})[1]
    local queued = self:queue()[file.key] ~= nil
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = T(_("“%1” is not on the device yet."), file.name),
        buttons = {
            {{ text = T(_("Download now into %1"), dir or cfg.base), callback = function()
                UIManager:close(dlg)
                self:downloadNow(item, dir)
            end }},
            {{ text = queued and _("Remove from Read later") or _("Read later (download at the next sync)"), callback = function()
                UIManager:close(dlg)
                self:toggleQueue(item, dir)
            end }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }},
        },
    }
    UIManager:show(dlg)
end

function Browser:toggleQueue(item, dir)
    local cfg = self.plugin:config()
    local file = item.file
    if self:queue()[file.key] then
        sync.queue_remove(cfg, file.key)
    else
        sync.queue_add(cfg, dir, file, item.book and item.book.title or file.name)
        UIManager:show(InfoMessage:new{ text = T(_("“%1” will download at the next sync."), file.name), timeout = 2 })
    end
    self:refresh()
end

function Browser:downloadNow(item, dir)
    local file = item.file
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
            end, item.dest)
            Trapper:clear()
            if not ok then p, err = nil, p end
            if p then
                if self:queue()[file.key] then sync.queue_remove(self.plugin:config(), file.key) end
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
end

--- Long-press on a book: what the saved catalog knows about it, with Open / Download.
function Browser:details(item)
    local b, f = item.book or {}, item.file
    local cfg = self.plugin:config()
    local path = self:localCopy(cfg, item, self:loadState())
    local lines = { b.title or f.name }
    if b.authors and #b.authors > 0 then lines[#lines + 1] = T(_("by %1"), table.concat(b.authors, ", ")) end
    if b.series and b.series ~= "" then
        lines[#lines + 1] = T(_("Series: %1"), b.series .. (b.number and (" #" .. num(b.number)) or ""))
    end
    if b.folders and #b.folders > 0 then lines[#lines + 1] = T(_("Folders: %1"), table.concat(b.folders, ", ")) end
    lines[#lines + 1] = T(_("File: %1"), f.name .. (f.size and string.format(" (%.1f MB)", f.size / 1048576) or ""))
    local st = (util.load_table(cfg.status_path or "") or {})[f.key]
    local extras = require("librarysync/extras")
    local status = st and st.status or (b.status and extras.FROM_SERVER[b.status])
    if status then lines[#lines + 1] = T(_("Status: %1"), _(extras.LABEL[status] or status)) end
    if st and st.rating then lines[#lines + 1] = T(_("Your rating: %1"), string.rep("★", math.floor(st.rating + 0.5))) end
    lines[#lines + 1] = path and T(_("On this device: %1"), path)
        or self:queue()[f.key] and _("Not on this device yet: on the Read later list.") or _("Not on this device yet.")
    local summaries = util.load_table(cfg.summaries_path) or {}
    local summary = b.id and summaries[b.id]
    if summary and summary ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = summary
    end
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local row = { { text = _("Close"), callback = function() UIManager:close(viewer) end } }
    if path then
        row[#row + 1] = { text = _("Open"), callback = function() UIManager:close(viewer) self:openBook(item) end }
    else
        local dir = item.folder_title or (f.folders or {})[1]
        row[#row + 1] = { text = self:queue()[f.key] and _("Remove from Read later") or _("Read later"),
                          callback = function() UIManager:close(viewer) self:toggleQueue(item, dir) end }
        row[#row + 1] = { text = _("Download"), callback = function() UIManager:close(viewer) self:downloadNow(item, dir) end }
    end
    viewer = TextViewer:new{
        title = bookTitle(b.title and b or { title = f.name }),
        text = table.concat(lines, "\n"),
        buttons_table = { row },
    }
    UIManager:show(viewer)
end

function Browser:syncFolder(url, title)
    local cfg = self.plugin:checkReady()
    if not cfg then return end
    cfg.only = { url = url, name = title }
    self.plugin:runSync(cfg)
end

return Browser
