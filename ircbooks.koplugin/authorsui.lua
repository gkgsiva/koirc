--[[--
Followed authors: follow an author from a result, a Hardcover book or the
open book; see who is followed (here and on Hardcover); turn on
auto-download of their new books. New books show under "New releases" after
a Hardcover sync (koirc/follows.lua).
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local Follows = require("koirc/follows")
local Hardcover = require("koirc/hardcover")

local M = {}

-- A followed author's book that was not found is tried again after this.
local RETRY_AFTER = 7 * 86400

local function notify(text)
    local ok = pcall(function() require("ui/widget/notification"):notify(text) end)
    if not ok then UIManager:show(InfoMessage:new{ text = text, timeout = 3 }) end
end

--- Authors followed on Hardcover, as seen at the last sync.
local function hardcoverAuthors(plugin)
    local ok, list = pcall(function() return plugin.hardcover:storeValue("authors_followed") end)
    local out = {}
    for _i, a in ipairs(ok and type(list) == "table" and list or {}) do
        if a.hardcover and a.name then out[#out + 1] = a end
    end
    return out
end

function M.isFollowed(plugin, name)
    local a = Follows.find(plugin.settings, name)
    if a and a.mine then return true end
    local k = Hardcover.normalize(name)
    for _i, h in ipairs(hardcoverAuthors(plugin)) do
        if Hardcover.normalize(h.name) == k then return true end
    end
    return false
end

--- Look for new books by followed authors at the next sync.
local function checkSoon(plugin)
    pcall(function()
        local hc = plugin.hardcover
        local meta = hc:storeValue("sync_meta")
        if type(meta) == "table" and meta.authors then
            meta.authors = nil
            hc:setStoreValue("sync_meta", meta)
        end
    end)
end

function M.follow(plugin, name, after)
    local a, new = Follows.add(plugin.settings, name)
    if not a then return end
    plugin:saveSettings()
    checkSoon(plugin)
    local text
    if not new then
        text = T(_("You already follow %1."), a.name)
    elseif plugin.hardcover:hasToken() then
        text = T(_("Following %1.\n\nNew books by them show under “New releases” after the next Hardcover sync. Turn on auto-download in Followed authors to get them in the background."), a.name)
    else
        text = T(_("Following %1.\n\nAdd your Hardcover API key to be told about new books by them."), a.name)
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
    if after then after() end
end

local function askName(plugin, on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Follow an author"),
        input_hint = _("Author name, e.g. Brandon Sanderson"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Follow"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    M.follow(plugin, name, on_done)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- New releases by this author from the last sync.
local function newBooksBy(plugin, name)
    local k = Hardcover.normalize(name)
    local out = {}
    local ok, books = pcall(function() return plugin.hardcover:cache()["books:new:all"] end)
    for _i, b in ipairs(ok and type(books) == "table" and books or {}) do
        for n in tostring(b.authors or b.author or ""):gmatch("[^,]+") do
            if Hardcover.normalize(n) == k then out[#out + 1] = b break end
        end
    end
    return out
end

local function showAuthor(plugin, a, refresh)
    local s = plugin.settings
    local entry = Follows.find(s, a.name)
    local auto = entry and entry.auto
    local dialog
    local function close() UIManager:close(dialog) end
    local new = newBooksBy(plugin, a.name)
    local lines = { a.name }
    if a.hardcover then lines[#lines + 1] = _("Followed on Hardcover") end
    if entry and entry.mine then
        if entry.id then lines[#lines + 1] = _("Followed here")
        elseif entry.not_found then lines[#lines + 1] = _("Followed here · not found on Hardcover (check the spelling)")
        else lines[#lines + 1] = _("Followed here · looked up on Hardcover at the next sync") end
    end
    if #new > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("New books:")
        for i = 1, math.min(#new, 6) do
            local b = new[i]
            lines[#lines + 1] = "• " .. b.title .. (b.release_date and (" (" .. b.release_date .. ")") or "")
        end
    end
    local buttons = {
        {{
            text = T(_("Search IRC for %1"), a.name),
            callback = function()
                close()
                plugin.last_query = a.name
                NetworkMgr:runWhenOnline(function() plugin:doSearch(a.name) end)
            end,
        }},
        {{
            text = auto and _("Auto-download new books: on ✓") or _("Auto-download new books: off"),
            callback = function()
                close()
                Follows.setAuto(s, a.name, not auto)
                plugin:saveSettings()
                if not auto then
                    notify(T(_("New books by %1 will download in the background after a sync, once they are out."), a.name))
                end
                showAuthor(plugin, a, refresh)
                if refresh then refresh() end
            end,
        }},
    }
    if #new > 0 then
        buttons[#buttons + 1] = {{
            text = T(_("Download the %1 new books now"), #new),
            callback = function()
                close()
                local missing = {}
                plugin.hardcover:localFiles()
                local today = os.date("%Y-%m-%d")
                for _i, b in ipairs(new) do
                    if Follows.released(b, today) and not plugin.hardcover:localFile(b) then missing[#missing + 1] = b end
                end
                if #missing == 0 then
                    UIManager:show(InfoMessage:new{ text = _("They are on the device already, or not out yet.") })
                    return
                end
                plugin:startQueue(missing, a.name)
            end,
        }}
    end
    if entry and entry.mine then
        buttons[#buttons + 1] = {{
            text = _("Unfollow"),
            callback = function()
                close()
                if a.hardcover then
                    -- Keep the Hardcover follow (and its auto setting).
                    entry.mine = nil
                else
                    Follows.remove(s, a.name)
                end
                plugin:saveSettings()
                if refresh then refresh() end
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = close }}
    dialog = ButtonDialog:new{ title = table.concat(lines, "\n"), title_align = "left", buttons = buttons }
    UIManager:show(dialog)
end

--- Everyone followed: here and on Hardcover, without doubles.
function M.all(plugin)
    local out, seen = {}, {}
    for _i, a in ipairs(Follows.list(plugin.settings)) do
        if a.mine then
            out[#out + 1] = { name = a.name, id = a.id, mine = true }
            seen[Hardcover.normalize(a.name)] = out[#out]
        end
    end
    for _i, h in ipairs(hardcoverAuthors(plugin)) do
        local k = Hardcover.normalize(h.name)
        if seen[k] then
            seen[k].hardcover = true
        else
            out[#out + 1] = { name = h.name, id = h.id, hardcover = true }
            seen[k] = out[#out]
        end
    end
    table.sort(out, function(x, y) return Hardcover.normalize(x.name) < Hardcover.normalize(y.name) end)
    return out
end

function M.showList(plugin)
    local hc = plugin.hardcover
    local menu
    local function items()
        local list = {
            { text = _("Follow an author…"), add = true, bold = true },
        }
        local all = M.all(plugin)
        for _i, a in ipairs(all) do
            local e = Follows.find(plugin.settings, a.name)
            local tags = {}
            if a.hardcover then tags[#tags + 1] = _("Hardcover") end
            if e and e.auto then tags[#tags + 1] = _("auto ⬇") end
            if e and e.mine and not e.id and e.not_found then tags[#tags + 1] = _("not found") end
            local n = #newBooksBy(plugin, a.name)
            if n > 0 then tags[#tags + 1] = T(_("%1 new"), n) end
            list[#list + 1] = { text = a.name, mandatory = table.concat(tags, " · "), author = a }
        end
        if #all == 0 then
            list[#list + 1] = {
                text = _("Nobody yet. Hold a search result, or open a Hardcover book, to follow its author."),
                dim = true,
            }
        end
        if not hc:hasToken() then
            list[#list + 1] = { text = _("New-book alerts need your Hardcover API key (Settings)."), dim = true }
        end
        return list
    end
    local function refresh()
        if menu and menu.switchItemTable then menu:switchItemTable(_("Followed authors"), items()) end
    end
    menu = hc:makeMenu{
        title = _("Followed authors"),
        items = items(),
        on_select = function(item)
            if item.add then
                askName(plugin, refresh)
            elseif item.author then
                showAuthor(plugin, item.author, refresh)
            end
        end,
    }
    UIManager:show(menu)
end

--- After a sync: queue new books by authors with auto-download on.
function M.afterSync(hc, scheduled)
    local plugin = hc.plugin
    local s = plugin.settings
    if scheduled and not hc:autoSyncAllowed() then return end
    local q = plugin.queue
    if not q or q:isRunning() or q:isPaused() then return end
    local books = hc:cache()["books:new:all"]
    if type(books) ~= "table" or #books == 0 then return end
    local now = os.time()
    local tried = hc:storeValue("authors_tried") or {}
    -- Forget old tries, so a book not found is looked for again.
    for id, t in pairs(tried) do
        if now - (tonumber(t) or 0) > RETRY_AFTER then tried[id] = nil end
    end
    hc:localFiles()
    local pick = Follows.autoPicks(books, s, {
        has_file = function(b) return hc:localFile(b) and true or false end,
        tried = tried, now = now, today = os.date("%Y-%m-%d", now),
    })
    if #pick == 0 then return end
    hc:setStoreValue("authors_tried", tried)
    logger.info("ircbooks: followed authors: queueing", #pick, "new books")
    -- Started by itself: background folder, no question; waits for the
    -- download schedule.
    q:start(pick, _("New books by followed authors"), { dir = plugin:getAutoDownloadDir() })
end

return M
