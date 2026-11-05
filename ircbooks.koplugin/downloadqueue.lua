--[[--
Background download queue: searches IRC for several books one after another,
picks the result that best matches each book (preferred format first) and
downloads it, without blocking the screen. Progress shows as short
notifications so you can keep reading.

There is one queue for the whole KOReader session, so it keeps running when
you open a book from the file browser or go back to it.
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Hardcover = require("koirc/hardcover")
local results = require("koirc/results")

-- Wait between books so search bots don't see us as flooding.
local PAUSE = 4
-- Results to try per book when a bot does not send the file.
local MAX_TRIES = 3
-- Give up after this many failures in a row (e.g. the network is gone).
local MAX_ERRORS_IN_ROW = 3

local Queue = {}
Queue.__index = Queue

--- env:
--   fetcher()          the shared Fetcher
--   start_ticking()    drive the fetcher
--   settings()         plugin settings table
--   download_dir()     folder to save into
--   after_download(path, book, entry) -> new path (rename, metadata)
--   on_book_done(book, path)
--   on_change()        called when progress changes (to refresh menus)
function Queue.new(env)
    local self = setmetatable({}, Queue)
    self.env = env
    self.items = {}
    return self
end

local function notify(text)
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and Notification then
        local shown = pcall(function()
            if Notification.notify then
                Notification:notify(text)
            else
                UIManager:show(Notification:new{ text = text })
            end
        end)
        if shown then return end
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

function Queue:isRunning()
    return self.running == true
end

function Queue:isPaused()
    return not self.running and self.paused == true and self:remaining() > 0
end

function Queue:remaining()
    local n = 0
    for _i, item in ipairs(self.items) do
        if not item.finished then n = n + 1 end
    end
    return n
end

--- Short text such as "2 of 5: Title".
function Queue:statusText()
    local item = self.items[self.index or 0]
    if not item then return "" end
    return T(_("%1 of %2: %3"), self.index, #self.items, item.book.title)
end

--- books: array of Hardcover books ({id, title, author, ...}).
function Queue:start(books, name)
    if self.running then return false end
    self.items = {}
    for _i, b in ipairs(books) do
        self.items[#self.items + 1] = { book = b, query = Hardcover.searchQuery(b) }
    end
    if #self.items == 0 then return false end
    self.name = name
    self.index = 0
    self.done, self.failed = {}, {}
    self.errors_in_row = 0
    self.running = true
    self.paused = false
    self.gen = (self.gen or 0) + 1
    notify(T(_("Downloading %1 books in the background."), #self.items))
    self:next()
    return true
end

--- Continue after a pause (device slept or Wi-Fi went off).
function Queue:resume()
    if self.running or not self.paused then return end
    self.running = true
    self.paused = false
    self.gen = (self.gen or 0) + 1
    self.errors_in_row = 0
    -- Retry the book that was interrupted.
    local cur = self.items[self.index]
    if cur and not cur.finished then self.index = self.index - 1 end
    notify(_("Continuing background downloads."))
    self:next()
end

function Queue:changed()
    if self.env.on_change then pcall(self.env.on_change) end
end

function Queue:scheduleNext(delay)
    UIManager:unschedule(self.next_fn)
    self.next_fn = function() self:next() end
    UIManager:scheduleIn(delay or PAUSE, self.next_fn)
end

--- True while the queue run that was current at gen is still going.
function Queue:live(gen)
    return self.running and self.gen == gen
end

function Queue:next()
    if not self.running then return end
    local gen = self.gen
    local fetcher = self.env.fetcher()
    if fetcher:isBusy() then
        -- A search the user started themselves; wait for it.
        self:scheduleNext(5)
        return
    end
    self.index = self.index + 1
    local item = self.items[self.index]
    if not item then return self:finish() end
    self:changed()
    notify(T(_("Searching %1"), self:statusText()))
    local ok = fetcher:search(item.query, {
        on_done = function(list) if self:live(gen) then self:onResults(item, list) end end,
        on_error = function(err) if self:live(gen) then self:onFailed(item, err, true) end end,
    })
    if not ok then
        self.index = self.index - 1
        self:scheduleNext(5)
        return
    end
    self.env.start_ticking()
end

function Queue:onResults(item, list)
    if not self.running then return end
    local s = self.env.settings()
    local prefs = results.parseFormats(s.preferred_formats or results.DEFAULT_PREFERRED)
    list = results.filter(list, s.formats)
    local ranked = Hardcover.rankResults(item.book, list, function(e) return results.formatRank(e, prefs) end)
    local candidates = {}
    for _i, e in ipairs(ranked) do
        if not results.ARCHIVES[results.bookExt(e) or ""] then candidates[#candidates + 1] = e end
    end
    self.errors_in_row = 0
    if #candidates == 0 then
        self:onFailed(item, #list == 0 and _("not found") or _("no matching result"))
        return
    end
    self:download(item, candidates, 1)
end

function Queue:download(item, candidates, try)
    if not self.running then return end
    local entry = candidates[try]
    local gen = self.gen
    local fetcher = self.env.fetcher()
    notify(T(_("Downloading %1"), self:statusText()))
    local ok = fetcher:download(entry, self.env.download_dir(), {
        on_done = function(path)
            if not self:live(gen) then return end
            item.finished = true
            self.errors_in_row = 0
            if self.env.after_download then
                local ok, new_path = pcall(self.env.after_download, path, item.book, entry)
                if ok and new_path then path = new_path end
            end
            self.done[#self.done + 1] = { book = item.book, path = path }
            pcall(self.env.on_book_done, item.book, path)
            self:changed()
            self:scheduleNext()
        end,
        on_error = function(err)
            if not self:live(gen) then return end
            logger.warn("ircbooks: background download failed:", entry.request, err)
            if try < math.min(MAX_TRIES, #candidates) then
                -- Another bot may have the same book.
                UIManager:scheduleIn(PAUSE, function()
                    if self:live(gen) then self:download(item, candidates, try + 1) end
                end)
            else
                self:onFailed(item, err, true)
            end
        end,
    })
    if not ok then
        UIManager:scheduleIn(5, function()
            if self:live(gen) then self:download(item, candidates, try) end
        end)
        return
    end
    self.env.start_ticking()
end

function Queue:onFailed(item, why, is_error)
    if not self.running then return end
    item.finished = true
    self.failed[#self.failed + 1] = { book = item.book, why = tostring(why) }
    if is_error then
        self.errors_in_row = self.errors_in_row + 1
        if self.errors_in_row >= MAX_ERRORS_IN_ROW then
            self:finish(_("Stopped after several errors in a row:") .. "\n" .. tostring(why))
            return
        end
    end
    self:changed()
    self:scheduleNext()
end

--- Give up on the current book (its job was dropped) and go on.
function Queue:skipCurrent(why)
    local item = self.items[self.index or 0]
    if not self.running or not item or item.finished then return end
    self.gen = (self.gen or 0) + 1
    self:onFailed(item, why, true)
end

--- Stop for good (user request).
function Queue:stop()
    if not self.running and not self.paused then return end
    local fetcher = self.env.fetcher()
    if self.running then fetcher:cancel() end
    self:finish(_("Stopped."))
end

--- Stop for now but remember what is left (device sleeps, Wi-Fi off).
function Queue:pause()
    if not self.running then return end
    UIManager:unschedule(self.next_fn)
    self.running = false
    self.paused = true
    self.gen = (self.gen or 0) + 1
    self:changed()
end

function Queue:finish(note)
    UIManager:unschedule(self.next_fn)
    self.gen = (self.gen or 0) + 1
    self.running = false
    self.paused = false
    self:changed()
    local lines = {}
    if note then lines[#lines + 1] = note end
    lines[#lines + 1] = T(_("Background downloads: %1 downloaded, %2 not found."), #self.done, #self.failed)
    if #self.done > 0 then
        local names = {}
        for _i, d in ipairs(self.done) do names[#names + 1] = "✓ " .. d.book.title end
        lines[#lines + 1] = table.concat(names, "\n")
    end
    if #self.failed > 0 then
        local names = {}
        for _i, f in ipairs(self.failed) do names[#names + 1] = T("✗ %1 (%2)", f.book.title, f.why) end
        lines[#lines + 1] = table.concat(names, "\n")
        lines[#lines + 1] = _("Tap a missing book in the list to search for it yourself.")
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n\n") })
end

return Queue
