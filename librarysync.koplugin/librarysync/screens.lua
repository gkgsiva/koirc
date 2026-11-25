-- The v2.7 screens of the plugin: progress conflicts, the wishlist, books kept offline, reading
-- time left and the update notice. Added to the LibrarySync widget by main.lua:
--   require("librarysync/screens")(LibrarySync, { Job =, notify =, version = })
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local util = require("librarysync/util")
local sync = require("librarysync/sync")
local extras = require("librarysync/extras")
local conflicts = require("librarysync/conflicts")
local estimate = require("librarysync/estimate")
local wishlist = require("librarysync/wishlist")
local update = require("librarysync/update")

return function(LS, ctx)

local Job = ctx.Job

--- A full-screen list. Always named: ZenOS takes unnamed full-screen lists for its Collections
-- view and shrinks them, which shows the file browser's page bar underneath (second pager).
-- items: { text=, mandatory=, callback= }. Returns the menu and a close function.
function LS:listMenu(title, subtitle, items)
    local Menu = require("ui/widget/menu")
    local menu
    local function close()
        local m = menu
        menu = nil
        if m then UIManager:close(m) end
    end
    menu = Menu:new{
        name = "librarysync_list",
        title = title, subtitle = subtitle,
        item_table = items, is_popout = false, covers_fullscreen = true,
        is_borderless = true, title_bar_fm_style = true,
        width = require("device").screen:getWidth(), height = require("device").screen:getHeight(),
        onMenuSelect = function(_m, item) if item.callback then item.callback() end return true end,
        close_callback = close,
    }
    UIManager:show(menu)
    return menu, close
end

local function pct(p) return math.floor((tonumber(p) or 0) * 100 + 0.5) .. "%" end
local function when(t) return t and os.date("%a %d %b %H:%M", t) or "?" end

-------------------------------------------------------------------------------
-- Progress conflicts
-------------------------------------------------------------------------------

function LS:conflictCfg()
    local cfg = self:config()
    cfg.positions_file = self:dataPath("positions")
    cfg.remote_path = self:dataPath("remote")
    return cfg
end

function LS:conflictCount()
    local ok, n = pcall(conflicts.count, { conflicts_path = self:dataPath("conflicts") })
    return ok and n or 0
end

--- The list of books whose place differs between this device and the Library.
function LS:showConflicts()
    local list = conflicts.list(self:conflictCfg())
    local menu, close
    local items = {}
    for _i, c in ipairs(list) do
        items[#items + 1] = {
            text = tostring(c.name),
            mandatory = T(_("here %1 · Library %2"), pct(c["local"].percent), pct(c.remote.percent)),
            callback = function()
                self:resolveConflict(c.key, function() if close then close() end self:showConflicts() end)
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = _("No conflicts. When this device and another one both moved a book's place since the last sync, the book is listed here to pick one.") }
    end
    menu, close = self:listMenu(_("Progress conflicts"), _("Read on this device and elsewhere · tap to pick"), items)
    return menu
end

--- Pick a place for one book: this device's or the Library's. after(): called once picked.
function LS:resolveConflict(key, after)
    local cfg = self:conflictCfg()
    local c = conflicts.load(cfg)[key]
    if not c then if after then after() end return end
    local here, there = c["local"] or {}, c.remote or {}
    local open = self.ui and self.ui.document and self:openKey() == key
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = T(_("“%1” was read in two places since the last sync.\n\nThis device: %2 (%3)\nThe Library (another device): %4 (%5)\n\nWhich place should it keep?"),
            tostring(c.name or key), pct(here.percent), when(here.at), pct(there.percent), when(there.at)),
        buttons = {
            {{ text = T(_("Keep this device's place (%1)"), pct(here.percent)), callback = function()
                UIManager:close(dlg)
                conflicts.keep_local(cfg, key)
                ctx.notify(_("Library: this device's place is sent at the next sync."))
                if after then after() end
            end }},
            {{ text = T(_("Use the Library's place (%1)"), pct(there.percent)), callback = function()
                UIManager:close(dlg)
                local p = conflicts.use_remote(cfg, key, function(fn) sync.update_state(cfg, fn) end)
                if open and p then
                    local Event = require("ui/event")
                    self.ui:handleEvent(Event:new("GotoPercent", p * 100))
                    local remote = util.load_table(cfg.remote_path) or {}
                    if remote[key] then remote[key].handled, remote[key].jump = true, nil util.save_table(cfg.remote_path, remote) end
                    self.last_percent = p
                else
                    ctx.notify(_("Library: the book opens at the Library's place next time."))
                end
                if after then after() end
            end }},
            {{ text = _("Decide later"), callback = function() UIManager:close(dlg) end }},
        },
    }
    UIManager:show(dlg)
end

-------------------------------------------------------------------------------
-- Books kept offline
-------------------------------------------------------------------------------

function LS:pinCfg() return { pins_path = self:dataPath("pins") } end

function LS:isPinned(key) return key ~= nil and extras.pinned(self:pinCfg(), key) end

function LS:setPinned(key, on)
    extras.set_pin(self:pinCfg(), key, on)
    local b = Job.browser
    if b and b.menu then pcall(b.refresh, b) end
end

function LS:pinnedCount()
    local n = 0
    for _k in pairs(extras.pins(self:pinCfg())) do n = n + 1 end
    return n
end

--- Books kept offline: tap to stop keeping one (or open it).
function LS:showPinned()
    local cfg = self:config()
    local state = util.load_table(self.state_path) or { files = {} }
    local cat = util.load_table(cfg.catalog_path) or {}
    local items, list = {}, {}
    for key, at in pairs(extras.pins(self:pinCfg())) do
        local b = extras.book_of(cat, key)
        local path
        for p in pairs((state.files or {})[key] or {}) do if util.file_size(p) then path = p break end end
        list[#list + 1] = { key = key, at = at, title = b and b.title or (path and path:match("([^/]+)$")) or key, path = path }
    end
    table.sort(list, function(a, b) return tostring(a.title):lower() < tostring(b.title):lower() end)
    local close
    for _i, e in ipairs(list) do
        items[#items + 1] = {
            text = "📌 " .. tostring(e.title),
            mandatory = e.path and _("on this device") or _("not on this device"),
            callback = function()
                local ButtonDialog = require("ui/widget/buttondialog")
                local dlg
                local rows = {}
                if e.path then
                    rows[#rows + 1] = {{ text = _("Open"), callback = function()
                        UIManager:close(dlg)
                        if close then close() end
                        if Job.browser then Job.browser:close() end
                        self:openFile(e.path)
                    end }}
                end
                rows[#rows + 1] = {{ text = _("Stop keeping offline"), callback = function()
                    UIManager:close(dlg)
                    self:setPinned(e.key, false)
                    if close then close() end
                    self:showPinned()
                end }}
                rows[#rows + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }}
                dlg = ButtonDialog:new{ title = tostring(e.title), buttons = rows }
                UIManager:show(dlg)
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = _("No books are kept offline. Long-press a book in the Library (or use Library: this book while reading) and choose Keep offline: cleanup, the storage budget and Remove finished books then leave it alone.") }
    end
    local _m
    _m, close = self:listMenu(_("Kept offline"), _("Never removed by cleanup or the storage budget"), items)
end

-------------------------------------------------------------------------------
-- Reading time left
-------------------------------------------------------------------------------

function LS:estimateCfg()
    local cfg = self:config()
    cfg.positions_file = self:dataPath("positions")
    return cfg
end

--- An estimator over the saved catalog (see estimate.estimator), or nil when turned off.
function LS:estimator(cat)
    if not self:get("show_time_left", true) then return nil end
    pcall(self.flushStats, self)
    local stats = util.load_table(self:dataPath("stats")) or {}
    local ok, est = pcall(estimate.estimator, self:estimateCfg(), stats, cat)
    return ok and est or nil
end

--- "about 3 h 20 min left (210 pages)" for a book, or a reason there is none.
function LS:timeLeftLine(est, book, file)
    if not est then return nil end
    local secs, pages, done = est.left(book, file)
    if done then return _("Time left: finished") end
    if secs then
        return T(_("Time left: %1 (%2 pages at your speed)"), _(estimate.long(secs)), pages)
    elseif pages then
        return T(_("Time left: %1 pages (read a little more for a time: your speed comes from the reading stats)"), pages)
    end
    return nil
end

--- The open book: time left from KOReader's page count and this reader's speed.
function LS:openBookTimeLeft()
    local doc = self.ui and self.ui.document
    if not doc then return nil end
    local pages = doc.getPageCount and doc:getPageCount()
    local page = self.current_page
    if not (pages and pages > 0) then return nil end
    pcall(self.flushStats, self)
    local spp = estimate.secs_per_page(util.load_table(self:dataPath("stats")) or {})
    local percent = page and page / pages
    if not percent then
        local ds = self.ui.doc_settings
        percent = ds and ds.readSetting and tonumber(ds:readSetting("percent_finished")) or 0
    end
    local secs, left = estimate.left{ percent = percent, screen_pages = pages, spp = spp }
    if secs then return T(_("%1 left in this book (%2 pages)"), _(estimate.long(secs)), left) end
    return T(_("%1 pages left (no reading speed yet)"), left or 0)
end

--- Remember the open book's page count and place (for the estimates in the Library lists).
function LS:notePages()
    local doc = self.ui and self.ui.document
    if not (doc and doc.file and doc.getPageCount) then return end
    local key = self:openKey()
    if not key then return end
    local pages = doc:getPageCount()
    local percent = self.current_page and pages and pages > 0 and math.min(1, self.current_page / pages) or nil
    estimate.note(self:dataPath("pages"), key, pages, percent)
end

-------------------------------------------------------------------------------
-- Wishlist
-------------------------------------------------------------------------------

function LS:wishCfg() return { wishlist_path = self:dataPath("wishlist") } end

local NOTE = {
    unsupported = _("This Library server has no Auto download lists yet: the wishes wait on this device until it is updated."),
    admin = _("Only an admin account can add to the Library's lists: the wishes wait on this device. Sign in with an admin account (or an admin's API token)."),
    account = _("This account may only use the catalog: the wishes wait on this device."),
}

local function wishState(e)
    if e.state == "arrived" then return _("in the Library") end
    if e.state == "waiting" then return _("sent at the next sync") end
    if e.server and wishlist.SERVER_TEXT[e.server] then return _(wishlist.SERVER_TEXT[e.server]) end
    return _("sent, the Library searches for it")
end

--- Ask for a book to add: "Title by Author".
function LS:addWish(prefill, after)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Add to the wishlist"),
        input = prefill or "",
        input_hint = _("Title by Author"),
        description = _("The next sync sends it to the Library, which searches for it and downloads it. Once it is in the Library, a sync brings it to this device."),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local title, author = wishlist.parse(dialog:getInputText())
                if not title then return end
                if not author then
                    UIManager:show(InfoMessage:new{ text = _("Add the author too: Title by Author. The Library needs it to find the right book."), timeout = 4 })
                    return
                end
                UIManager:close(dialog)
                local e, err = wishlist.add(self:wishCfg(), title, author)
                if e then
                    ctx.notify(T(_("“%1” is on the wishlist. The next sync sends it to the Library."), title))
                elseif err == "duplicate" then
                    UIManager:show(InfoMessage:new{ text = T(_("“%1” is already on the wishlist."), title), timeout = 3 })
                end
                if after then after() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LS:showWishlist()
    local cfg = self:wishCfg()
    local w = wishlist.load(cfg)
    local close
    local function reopen() if close then close() end self:showWishlist() end
    local items = {
        { text = "＋ " .. _("Add a book…"), callback = function() self:addWish(nil, reopen) end },
    }
    if w.note and NOTE[w.note] then items[#items + 1] = { text = "⚠ " .. NOTE[w.note] } end
    local list = {}
    for _i, e in ipairs(w.items) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        local x, y = a.state == "arrived" and 1 or 0, b.state == "arrived" and 1 or 0
        if x ~= y then return x < y end
        return (a.at or 0) > (b.at or 0)
    end)
    for _i, e in ipairs(list) do
        items[#items + 1] = {
            text = (e.state == "arrived" and "✓ " or "♡ ") .. wishlist.line(e),
            mandatory = wishState(e),
            callback = function()
                local ButtonDialog = require("ui/widget/buttondialog")
                local dlg
                local lines = { wishlist.line(e), T(_("Added: %1"), when(e.at)), wishState(e) }
                if e.detail then lines[#lines + 1] = e.detail end
                local rows = {}
                if e.state == "arrived" and e.key then
                    rows[#rows + 1] = {{ text = _("Show in the Library"), callback = function()
                        UIManager:close(dlg)
                        if close then close() end
                        self:browse()
                        if self.browser and self.browser.searchDevice then
                            pcall(function()
                                local hits = self.browser:searchDevice(e.title)
                                self.browser:push({ title = e.title, build = function() return self.browser:bookItems(hits) end })
                            end)
                        end
                    end }}
                end
                rows[#rows + 1] = {{ text = e.state == "arrived" and _("Remove from the list") or _("Take off the wishlist"), callback = function()
                    UIManager:close(dlg)
                    wishlist.remove(cfg, e.id)
                    reopen()
                end }}
                rows[#rows + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }}
                dlg = ButtonDialog:new{ title = table.concat(lines, "\n"), buttons = rows }
                UIManager:show(dlg)
            end,
        }
    end
    if #list == 0 then
        items[#items + 1] = { text = _("Books the Library does not have yet. Add one here (also offline): the next sync asks the Library to find it, and it comes to this device once it is there.") }
    end
    items[#items + 1] = { text = "⟳ " .. _("Sync now"), callback = function() if close then close() end self:syncNow() end }
    local _m
    _m, close = self:listMenu(_("Wishlist"), w.checked_at and T(_("Checked with the Library: %1"), when(w.checked_at)) or nil, items)
end

-------------------------------------------------------------------------------
-- Update notice
-------------------------------------------------------------------------------

function LS:updateInfo()
    local u = util.load_table(self:dataPath("update"))
    if u and u.latest and update.newer(u.latest, ctx.version) then return u end
    return nil
end

function LS:updateLine()
    local u = self:updateInfo()
    if u then return T(_("Update available: %1 (this is v%2)"), u.latest, ctx.version) end
    return nil
end

function LS:showUpdate(u)
    u = u or self:updateInfo()
    local TextViewer = require("ui/widget/textviewer")
    local lines = {}
    if u then
        lines[#lines + 1] = T(_("Library sync %1 is out (you have v%2)."), u.latest, ctx.version)
        if u.published then lines[#lines + 1] = T(_("Released: %1"), tostring(u.published):sub(1, 10)) end
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("To install: Storefront (Tools ▸ Storefront) updates it, or download the zip from the page below and unpack it into koreader/plugins, then restart KOReader.")
        lines[#lines + 1] = tostring(u.url or update.PAGE)
        if u.zip then lines[#lines + 1] = tostring(u.zip) end
        local notes = update.plain(u.notes)
        if notes ~= "" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = _("What changed:")
            lines[#lines + 1] = notes
        end
    else
        local s = util.load_table(self:dataPath("update")) or {}
        lines[#lines + 1] = T(_("You have the latest version (v%1)."), ctx.version)
        if s.checked_at then lines[#lines + 1] = T(_("Last checked: %1"), when(s.checked_at)) end
        if s.error then lines[#lines + 1] = T(_("The last check failed: %1"), tostring(s.error)) end
    end
    UIManager:show(TextViewer:new{ title = _("Library sync updates"), text = table.concat(lines, "\n") })
end

--- Ask GitHub now (on request only).
function LS:checkUpdateNow()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            Trapper:info(_("Checking for a newer Library sync…"))
            local httpmod = require("librarysync/http")
            local ok, saved = pcall(update.check, { update_path = self:dataPath("update") }, httpmod.get)
            Trapper:clear()
            if not ok then
                UIManager:show(InfoMessage:new{ text = T(_("Could not check for updates: %1"), tostring(saved)) })
                return
            end
            if saved.error and not self:updateInfo() then
                UIManager:show(InfoMessage:new{ text = T(_("Could not check for updates: %1"), tostring(saved.error)) })
                return
            end
            self:showUpdate()
        end)
    end)
end

end
