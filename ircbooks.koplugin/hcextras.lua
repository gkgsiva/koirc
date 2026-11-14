--[[--
More Hardcover screens, added to HardcoverUI:
- Book preview: description, page count and rating before downloading.
- Series completion: the volumes of each tracked series that are not on the
  device, queued for download in one tap.
- Auto-tag: genres, Hardcover lists and shelves written to a downloaded
  book's keywords, so KOReader's book information and metadata search find
  them.

These use the data saved by "Sync with Hardcover". They send a request only
when something is not saved yet (a preview's rating, a series never opened,
a book's genres), one at a time, and genres are remembered.
]]

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local Hardcover = require("koirc/hardcover")
local Collections = require("collections")

local M = {}

-- Genres written per book, and books asked for per request.
local MAX_GENRES = 5
local GENRE_BATCH = 25

local function isOnline()
    local ok, online = pcall(function()
        if NetworkMgr.isOnline then return NetworkMgr:isOnline() end
        return NetworkMgr:isConnected()
    end)
    return ok and online
end

--- Plain text from a description that may hold HTML or Markdown bits.
function M.cleanDescription(text)
    if type(text) ~= "string" then return nil end
    local t = text:gsub("\r\n?", "\n")
    t = t:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n\n"):gsub("<[^>]+>", "")
    t = t:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " ")
    t = t:gsub("\n%s*\n%s*\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then return nil end
    return t
end

--- "★★★★☆ 4.2 (1,234 ratings)".
function M.ratingText(rating, count)
    rating = tonumber(rating)
    if not rating or rating <= 0 then return nil end
    local full = math.floor(rating + 0.25)
    local stars = string.rep("★", full) .. string.rep("☆", math.max(0, 5 - full))
    local s = string.format("%s %.1f", stars, rating)
    count = tonumber(count)
    if count and count > 0 then s = s .. " " .. T(_("(%1 ratings)"), count) end
    return s
end

--- The preview text of a book.
function M.previewText(book, on_device)
    local lines = {}
    if book.authors and book.authors ~= "" then lines[#lines + 1] = T(_("by %1"), book.authors) end
    if book.series then lines[#lines + 1] = book.series end
    local facts = {}
    if book.pages then facts[#facts + 1] = T(_("%1 pages"), book.pages) end
    local year = book.release_year or (book.release_date and tonumber(book.release_date:match("^(%d%d%d%d)")))
    if year then facts[#facts + 1] = tostring(year) end
    if #facts > 0 then lines[#lines + 1] = table.concat(facts, " · ") end
    local r = M.ratingText(book.rating, book.ratings_count)
    lines[#lines + 1] = r or _("No rating on Hardcover yet")
    if on_device then lines[#lines + 1] = T(_("On device: %1"), on_device) end
    local d = M.cleanDescription(book.description)
    lines[#lines + 1] = ""
    lines[#lines + 1] = d or _("Hardcover has no description for this book.")
    return table.concat(lines, "\n")
end

function M.install(HardcoverUI)

--- Show description, pages and rating. Loads the rating from Hardcover
-- (one request) when the saved copy predates it. buttons: extra rows.
function HardcoverUI:showPreview(book, buttons)
    if book.id and book.rating == nil and not book.preview_loaded and isOnline() and self:hasToken() then
        book.preview_loaded = true
        local full = self:withLoading(_("Loading from Hardcover…"), function() return self.client:getBook(book.id) end)
        if full then
            for _i, k in ipairs({ "rating", "ratings_count", "pages", "description", "release_year", "series" }) do
                if book[k] == nil then book[k] = full[k] end
            end
        end
    end
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local rows = {}
    for _i, row in ipairs(buttons or {}) do
        local r = {}
        for j, b in ipairs(row) do
            r[j] = { text = b.text, callback = function()
                UIManager:close(viewer)
                b.callback()
            end }
        end
        rows[#rows + 1] = r
    end
    rows[#rows + 1] = {{ text = _("Close"), callback = function() UIManager:close(viewer) end }}
    viewer = TextViewer:new{
        title = book.title,
        text = M.previewText(book, book.path),
        buttons_table = rows,
    }
    UIManager:show(viewer)
end

--- Preview for an IRC result: find the book on Hardcover first.
function HardcoverUI:previewEntry(entry, on_download)
    local guess = Hardcover.entryBook(entry)
    local query = Hardcover.searchQuery(guess)
    if not self.json or not self:hasToken() then
        UIManager:show(InfoMessage:new{ text = _("Set a Hardcover API key first (Settings → Hardcover).") })
        return
    end
    if not isOnline() then
        NetworkMgr:runWhenOnline(function() self:previewEntry(entry, on_download) end)
        return
    end
    local found, err = self:withLoading(_("Looking for this book on Hardcover…"), function()
        return self.client:searchBooks(query)
    end)
    if not found then
        if Hardcover.isBusy(err) then err = self.busyText() end
        UIManager:show(InfoMessage:new{ text = tostring(err or _("Could not reach Hardcover.")) })
        return
    end
    local book = found[1]
    for _i, b in ipairs(found) do
        if Hardcover.resultScore(b, entry) then book = b break end
    end
    if not book then
        UIManager:show(InfoMessage:new{ text = T(_("“%1” was not found on Hardcover."), query) })
        return
    end
    self:showPreview(book, on_download and {{ { text = _("Download"), callback = on_download } }} or nil)
end

-------------------------------------------------------------------------------
-- Series completion
-------------------------------------------------------------------------------

--- Tracked series with what is on the device: array of {id, name, books,
-- have, missing (books), loaded}. Uses saved data only.
function HardcoverUI:seriesCompletion()
    local cache = self:cache()
    local series = type(cache.series) == "table" and cache.series or {}
    self:localFiles()
    local out, seen = {}, {}
    for _k, part in ipairs({ series.following or {}, series.started or {} }) do
        for _i, sr in ipairs(part) do
            if not seen[sr.id] then
                seen[sr.id] = true
                local books = cache["books:series:" .. tostring(sr.id)]
                local e = { id = sr.id, name = sr.name, count = sr.count, loaded = type(books) == "table", missing = {}, have = 0, total = 0 }
                if e.loaded then
                    for _j, b in ipairs(books) do
                        e.total = e.total + 1
                        b.path = self:localFile(b)
                        if b.path then e.have = e.have + 1 else e.missing[#e.missing + 1] = b end
                    end
                end
                out[#out + 1] = e
            end
        end
    end
    -- Series with the fewest missing volumes (but some) first: closest to done.
    table.sort(out, function(a, b)
        local am, bm = #a.missing, #b.missing
        if (am == 0) ~= (bm == 0) then return am > 0 end
        if a.loaded ~= b.loaded then return a.loaded end
        if am ~= bm then return am < bm end
        return a.name:lower() < b.name:lower()
    end)
    return out
end

local function positions(books, max)
    local p = {}
    for i, b in ipairs(books) do
        if i > (max or 6) then p[#p + 1] = "…" break end
        p[#p + 1] = b.series_pos and ("#" .. string.format("%d", b.series_pos)) or b.title
    end
    return table.concat(p, ", ")
end

--- Queue books in the background (after the storage check).
function HardcoverUI:queueBooks(books, name)
    if #books == 0 then return end
    local q = self.plugin.queue
    if q:isRunning() then
        self.plugin:showQueueBusy()
        return
    end
    require("storage").guard(self.plugin, nil, function()
        NetworkMgr:runWhenOnline(function()
            q:start(books, name)
            if self.completion_menu then self:refreshCompletion() end
        end)
    end)
end

function HardcoverUI:showSeriesCompletion()
    if not self.json or not self:hasToken() then return self:open() end
    if self.completion_menu then UIManager:close(self.completion_menu) end
    local menu
    menu = self:makeMenu{
        title = _("Complete your series"),
        on_select = function(item) self:onCompletionSelected(item) end,
        on_close = function(m)
            if self.completion_menu == m then self.completion_menu = nil end
        end,
    }
    self.completion_menu = menu
    if not self:refreshCompletion() then
        UIManager:close(menu)
        self.completion_menu = nil
        return
    end
    UIManager:show(menu)
end

function HardcoverUI:refreshCompletion()
    local menu = self.completion_menu
    if not menu then return end
    if type(self:cache().series) ~= "table" then
        local res, err = self:fetch("series", _("Loading your series…"), function() self:showSeriesCompletion() end)
        if not res then
            if err then UIManager:show(InfoMessage:new{ text = err }) end
            return false
        end
    end
    local list = self:seriesCompletion()
    local all, n_series = {}, 0
    for _i, e in ipairs(list) do
        if #e.missing > 0 then
            n_series = n_series + 1
            for _j, b in ipairs(e.missing) do all[#all + 1] = b end
        end
    end
    local items = {}
    if #all > 0 then
        items[#items + 1] = {
            text = T(_("Download all %1 missing volumes in the background"), #all),
            mandatory = T(_("%1 series"), n_series),
            bold = true,
            queue_books = all,
            separator = true,
        }
    end
    for _i, e in ipairs(list) do
        local text, mandatory
        if not e.loaded then
            text = e.name
            mandatory = _("tap to load")
        elseif #e.missing == 0 then
            text = "✓ " .. e.name
            mandatory = T(_("all %1"), e.total)
        else
            text = T(_("%1 — missing %2"), e.name, positions(e.missing))
            mandatory = T(_("%1 of %2"), e.have, e.total)
        end
        items[#items + 1] = { text = text, mandatory = mandatory, series = e }
    end
    if #list == 0 then
        items[1] = { text = _("Follow a series on Hardcover's Series Tracker to see it here."), dim = true }
    end
    menu:switchItemTable(_("Complete your series"), items, -1)
    return true
end

function HardcoverUI:onCompletionSelected(item)
    if item.queue_books then
        self:queueBooks(item.queue_books, _("Missing series volumes"))
        return
    end
    local e = item.series
    if not e then return end
    if not e.loaded then
        -- One request for this series, then saved like the others.
        local books = self:fetch("books:series:" .. tostring(e.id), T(_("Loading “%1”…"), e.name),
                                 function() self:refreshCompletion() end)
        if books then
            Collections.mirrorSoon(self)
            self:refreshCompletion()
        end
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    if #e.missing > 0 then
        buttons[#buttons + 1] = {{
            text = T(_("Download the %1 missing volumes"), #e.missing),
            callback = function()
                UIManager:close(dialog)
                self:queueBooks(e.missing, e.name)
            end,
        }}
    end
    buttons[#buttons + 1] = {
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
        { text = _("Open series"), callback = function()
            UIManager:close(dialog)
            self:showBooks({ kind = "series", id = e.id, name = e.name })
        end },
    }
    dialog = ButtonDialog:new{
        title = #e.missing > 0 and T(_("%1\n\n%2 of %3 on the device.\nMissing: %4"), e.name, e.have, e.total, positions(e.missing, 30))
                                or T(_("%1\n\nEvery volume is on the device."), e.name),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-------------------------------------------------------------------------------
-- Auto-tag
-------------------------------------------------------------------------------

function HardcoverUI:tagsOn()
    return self:settings().hardcover_tags ~= false
end

--- Genres saved for books, by book id (string).
function HardcoverUI:savedGenres()
    if not self.genres then self.genres = self:storeValue("genres") or {} end
    return self.genres
end

--- Load the genres of books not looked up yet (batched). Returns false when
-- Hardcover could not be asked.
function HardcoverUI:loadGenres(books)
    local saved = self:savedGenres()
    local ids = {}
    for _i, b in ipairs(books) do
        if b.id and saved[tostring(b.id)] == nil then ids[#ids + 1] = b.id end
    end
    if #ids == 0 then return true end
    if not isOnline() or not self:hasToken() then return false end
    local changed = false
    for i = 1, #ids, GENRE_BATCH do
        local part = {}
        for j = i, math.min(#ids, i + GENRE_BATCH - 1) do part[#part + 1] = ids[j] end
        local res, err = self.client:getBookGenres(part, MAX_GENRES)
        if not res then
            logger.warn("ircbooks: could not load genres:", err)
            break
        end
        for _j, id in ipairs(part) do
            saved[tostring(id)] = res[tonumber(id) or id] or {}
            changed = true
        end
    end
    if changed then self:setStoreValue("genres", saved) end
    return true
end

--- Tags for a book: its genres, the Hardcover lists it is on, its series.
function HardcoverUI:tagsFor(book)
    local tags, seen = {}, {}
    local function add(t)
        if type(t) ~= "string" or t == "" then return end
        local k = t:lower()
        if seen[k] then return end
        seen[k] = true
        tags[#tags + 1] = t
    end
    for _i, g in ipairs(self:savedGenres()[tostring(book.id)] or {}) do add(g) end
    local cache = self:cache()
    local lists = type(cache.lists) == "table" and cache.lists.lists or {}
    local id = tostring(book.id)
    for _i, l in ipairs(lists) do
        for _j, b in ipairs(cache["books:list:" .. tostring(l.id)] or {}) do
            if tostring(b.id) == id then add(l.name) break end
        end
    end
    for _i, sh in ipairs(self:shelves()) do
        for _j, b in ipairs(cache["books:status:" .. tostring(sh.id)] or {}) do
            if tostring(b.id) == id then add(sh.name) break end
        end
    end
    if book.series_name then add(book.series_name) end
    return tags
end

--- Write tags into the keywords of every attached book (from saved data,
-- with genres loaded in a few requests).
function HardcoverUI:retagAll()
    local files = self:settings().hardcover_files or {}
    local byid = {}
    for _i, b in ipairs(self:allCachedBooks()) do byid[tostring(b.id)] = b end
    local todo = {}
    local lfs = require("libs/libkoreader-lfs")
    for id, path in pairs(files) do
        if type(path) == "string" and byid[id] and lfs.attributes(path, "mode") == "file" then
            todo[#todo + 1] = { book = byid[id], path = path }
        end
    end
    if #todo == 0 then
        UIManager:show(InfoMessage:new{ text = _("No attached books to tag. Download or attach books from your Hardcover lists first.") })
        return
    end
    local books = {}
    for i, t in ipairs(todo) do books[i] = t.book end
    self:withLoading(T(_("Loading genres for %1 books…"), #books), function() return self:loadGenres(books) end)
    local n = 0
    for _i, t in ipairs(todo) do
        local ok = pcall(self.applyMetadata, self, t.path, t.book, { no_cover = true })
        if ok then n = n + 1 end
    end
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
    UIManager:show(InfoMessage:new{ text = T(_("Tagged %1 books with their genres, lists and series."), n) })
end

end

return M
