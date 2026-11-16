--[[--
Combined collections: one KOReader collection holding the on-device books
of several Hardcover lists and series, plus single Hardcover books picked
by hand. For example "Fantasy" = the list "To read: fantasy" + the series
Mistborn and Stormlight + one standalone book.

Saved in settings.custom_collections as {name, sources = {cache keys},
books = {{id, title, author}}}. They are built with the mirrored
collections (collections.lua), so "Rebuild KOReader collections now" keeps
them up to date, and only books the plugin added are taken out again.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Collections = require("collections")

local M = {}

function M.list(settings)
    if type(settings.custom_collections) ~= "table" then settings.custom_collections = {} end
    return settings.custom_collections
end

function M.find(settings, name)
    for i, cc in ipairs(M.list(settings)) do
        if cc.name == name then return cc, i end
    end
end

--- Make a combined collection (or return the one with that name).
function M.create(settings, name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    local cc = M.find(settings, name)
    if cc then return cc, false end
    cc = { name = name, sources = {}, books = {} }
    local list = M.list(settings)
    list[#list + 1] = cc
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return cc, true
end

function M.toggleSource(cc, key)
    cc.sources = cc.sources or {}
    for i, k in ipairs(cc.sources) do
        if k == key then table.remove(cc.sources, i) return false end
    end
    cc.sources[#cc.sources + 1] = key
    return true
end

function M.hasSource(cc, key)
    for _i, k in ipairs(cc.sources or {}) do
        if k == key then return true end
    end
    return false
end

--- Add a single Hardcover book. Returns true when it is new.
function M.addBook(cc, book)
    cc.books = cc.books or {}
    for _i, b in ipairs(cc.books) do
        if tostring(b.id) == tostring(book.id) then return false end
    end
    cc.books[#cc.books + 1] = { id = book.id, title = book.title, author = book.author, authors = book.authors }
    return true
end

function M.removeBook(cc, id)
    for i, b in ipairs(cc.books or {}) do
        if tostring(b.id) == tostring(id) then table.remove(cc.books, i) return true end
    end
    return false
end

--- "2 lists or series · 1 book".
function M.describe(cc)
    return T(_("%1 lists or series · %2 single books"), #(cc.sources or {}), #(cc.books or {}))
end

--- The Hardcover lists and series that can be combined: {name, key}.
local function sources(hc)
    local out = {}
    for _i, g in ipairs(Collections.groups(hc:cache())) do
        out[#out + 1] = { name = g.name, key = g.key, series = g.key:match("^books:series:") ~= nil }
    end
    return out
end

local function sourceName(hc, key)
    for _i, s in ipairs(sources(hc)) do
        if s.key == key then return s.name end
    end
    return key
end

--- Update the KOReader collections now (after a change).
local function apply(hc)
    Collections.rebuild(hc)
end

local function askName(title, input, on_done)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = input or "",
        input_hint = _("e.g. Fantasy"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    on_done(name)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Tick the lists and series that go into cc.
function M.pickSources(plugin, cc, after)
    local hc = plugin.hardcover
    local all = sources(hc)
    if #all == 0 then
        UIManager:show(InfoMessage:new{ text = _("No Hardcover lists or series are saved yet. Run “Sync with Hardcover” first.") })
        return
    end
    local menu
    local function items()
        local list = {{ text = _("Done: update the collection"), done = true, bold = true, separator = true }}
        for _i, s in ipairs(all) do
            list[#list + 1] = {
                text = (M.hasSource(cc, s.key) and "☑ " or "☐ ") .. s.name,
                mandatory = s.series and _("series") or _("list"),
                source = s,
            }
        end
        return list
    end
    menu = hc:makeMenu{
        title = T(_("Lists and series in “%1”"), cc.name),
        items = items(),
        on_select = function(item)
            if item.done then
                UIManager:close(menu)
                plugin:saveSettings()
                if after then after() end
                apply(hc)
            elseif item.source then
                M.toggleSource(cc, item.source.key)
                item.text = (M.hasSource(cc, item.source.key) and "☑ " or "☐ ") .. item.source.name
                if not (menu.updateItems and pcall(menu.updateItems, menu, 1, true)) then
                    menu:switchItemTable(nil, items())
                end
            end
        end,
    }
    UIManager:show(menu)
end

local showList

local function showOne(plugin, cc)
    local hc = plugin.hardcover
    local dialog
    local function close() UIManager:close(dialog) end
    local lines = { cc.name, M.describe(cc) }
    for _i, key in ipairs(cc.sources or {}) do lines[#lines + 1] = "• " .. sourceName(hc, key) end
    for _i, b in ipairs(cc.books or {}) do lines[#lines + 1] = "• " .. tostring(b.title) end
    local buttons = {
        {{ text = _("Choose lists and series…"), callback = function()
            close()
            M.pickSources(plugin, cc)
        end }},
    }
    if #(cc.books or {}) > 0 then
        buttons[#buttons + 1] = {{ text = _("Remove single books…"), callback = function()
            close()
            local d
            local bs = {}
            for _i, b in ipairs(cc.books) do
                bs[#bs + 1] = {{ text = T(_("Remove “%1”"), tostring(b.title)), callback = function()
                    UIManager:close(d)
                    M.removeBook(cc, b.id)
                    plugin:saveSettings()
                    apply(hc)
                end }}
            end
            bs[#bs + 1] = {{ text = _("Close"), callback = function() UIManager:close(d) end }}
            d = ButtonDialog:new{ title = _("Single books"), buttons = bs }
            UIManager:show(d)
        end }}
    end
    buttons[#buttons + 1] = {
        { text = _("Rename…"), callback = function()
            close()
            askName(_("Rename the collection"), cc.name, function(name)
                name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if name == "" or M.find(plugin.settings, name) then return end
                cc.name = name
                plugin:saveSettings()
                apply(hc)
            end)
        end },
        { text = _("Delete"), callback = function()
            close()
            local _c, i = M.find(plugin.settings, cc.name)
            if i then table.remove(M.list(plugin.settings), i) end
            plugin:saveSettings()
            -- The books it added leave KOReader's collection too; books
            -- you added yourself stay.
            apply(hc)
        end },
    }
    buttons[#buttons + 1] = {
        { text = _("Update collections now"), callback = function() close() apply(hc) end },
        { text = _("Close"), callback = close },
    }
    dialog = ButtonDialog:new{ title = table.concat(lines, "\n"), title_align = "left", buttons = buttons }
    UIManager:show(dialog)
end

showList = function(plugin)
    local hc = plugin.hardcover
    local menu
    local function items()
        local list = {{ text = _("New combined collection…"), new = true, bold = true, separator = true }}
        for _i, cc in ipairs(M.list(plugin.settings)) do
            list[#list + 1] = { text = cc.name, mandatory = M.describe(cc), cc = cc }
        end
        if #list == 1 then
            list[#list + 1] = { text = _("One KOReader collection with the books of several Hardcover lists and series (and single books from a Hardcover book's dialog)."), dim = true }
        end
        return list
    end
    menu = hc:makeMenu{
        title = _("Combined collections"),
        items = items(),
        on_select = function(item)
            if item.new then
                askName(_("New combined collection"), "", function(name)
                    local cc = M.create(plugin.settings, name)
                    if not cc then return end
                    plugin:saveSettings()
                    UIManager:close(menu)
                    M.pickSources(plugin, cc)
                end)
            elseif item.cc then
                UIManager:close(menu)
                showOne(plugin, item.cc)
            end
        end,
    }
    UIManager:show(menu)
end
M.showList = showList

--- From a Hardcover book's dialog: put it in a combined collection, or
-- (when its file is on the device) in any KOReader collection.
function M.addBookDialog(plugin, book)
    local dialog
    local buttons = {}
    for _i, cc in ipairs(M.list(plugin.settings)) do
        buttons[#buttons + 1] = {{ text = T(_("Combined: %1"), cc.name), callback = function()
            UIManager:close(dialog)
            local new = M.addBook(cc, book)
            plugin:saveSettings()
            if new then apply(plugin.hardcover) else
                UIManager:show(InfoMessage:new{ text = _("It is in that collection already."), timeout = 2 })
            end
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("New combined collection…"), callback = function()
        UIManager:close(dialog)
        askName(_("New combined collection"), "", function(name)
            local cc = M.create(plugin.settings, name)
            if not cc then return end
            M.addBook(cc, book)
            plugin:saveSettings()
            apply(plugin.hardcover)
        end)
    end }}
    local AddColl = require("addcoll")
    if book.path and AddColl.available() then
        buttons[#buttons + 1] = {{ text = _("Another KOReader collection…"), callback = function()
            UIManager:close(dialog)
            AddColl.choose(nil, function(name)
                if name then AddColl.addAndTell(book.path, name) end
            end, { none = false })
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title = T(_("Add “%1” to which collection?\n\nIn a combined collection it stays linked to the Hardcover book: when you download it later, it shows up there."), book.title),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return M
