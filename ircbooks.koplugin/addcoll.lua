--[[--
Putting downloaded books into an existing KOReader collection (or a new
one): picked before a download, before background downloads, after a
download, or for several books in "Move or re-file books".

Needs KOReader 2024.04 or newer (several named collections).
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function rc()
    local ok, RC = pcall(require, "readcollection")
    if not ok or type(RC) ~= "table" or type(RC.coll) ~= "table" then return nil end
    if not RC.addCollection or not RC.addItem or not RC.write then return nil end
    return RC
end

function M.available()
    return rc() ~= nil
end

--- Is there a collection with this name? (A remembered pick may have been
-- deleted since; it is not made again.)
function M.exists(name)
    local RC = rc()
    return RC ~= nil and name ~= nil and RC.coll[name] ~= nil
end

--- How a collection is shown ("favorites" is KOReader's Favorites).
function M.label(name)
    local RC = rc()
    if RC and name == RC.default_collection_name then return _("Favorites") end
    return name
end

--- Collection names: Favorites first, then the rest by name.
function M.names()
    local RC = rc()
    if not RC then return {} end
    local fav = RC.default_collection_name
    local out = {}
    for name in pairs(RC.coll) do
        if name ~= fav then out[#out + 1] = name end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    if fav and RC.coll[fav] then table.insert(out, 1, fav) end
    return out
end

--- Add the files (a path or an array of paths) to the collection, making
-- it when it is not there. Returns how many were added, or nil and an error.
function M.add(paths, name)
    local RC = rc()
    if not RC then return nil, _("This KOReader version has no named collections.") end
    if type(paths) == "string" then paths = { paths } end
    if not name or name == "" then return 0 end
    if not RC.coll[name] then RC:addCollection(name) end
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    local n = 0
    for _i, p in ipairs(paths) do
        local real = ok_ffi and ffiutil.realpath and ffiutil.realpath(p) or p
        if real then
            local c = RC.coll[name]
            if not (c[real] or c[p]) then
                local ok = pcall(RC.addItem, RC, real, name)
                if ok then n = n + 1 end
            end
        end
    end
    local ok, err = pcall(RC.write, RC, { [name] = true })
    if not ok then
        logger.warn("ircbooks: could not save the collection:", err)
        return nil, tostring(err)
    end
    return n
end

--- Add and say so briefly.
function M.addAndTell(paths, name)
    local n, err = M.add(paths, name)
    if not n then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local count = type(paths) == "table" and #paths or 1
    if count == 1 then
        UIManager:show(InfoMessage:new{ text = T(_("Added to the collection “%1”."), M.label(name)), timeout = 2 })
    else
        UIManager:show(InfoMessage:new{ text = T(_("Added %1 books to the collection “%2”."), n, M.label(name)), timeout = 3 })
    end
end

local function askNew(on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("New collection"),
        input_hint = _("Collection name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Create"),
                is_enter_default = true,
                callback = function()
                    local name = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialog)
                    if name ~= "" then on_done(name) end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Pick a collection. on_done(name), or on_done(false) for "No
-- collection". current: the name picked now (ticked). opts.none: offer
-- "No collection" (default true).
function M.choose(current, on_done, opts)
    opts = opts or {}
    if not M.available() then
        UIManager:show(InfoMessage:new{ text = _("This KOReader version has no named collections (KOReader 2024.04 or newer is needed).") })
        return
    end
    local dialog
    local function pick(v)
        UIManager:close(dialog)
        on_done(v)
    end
    local buttons = {}
    if opts.none ~= false then
        buttons[#buttons + 1] = {{ text = _("No collection") .. (not current and "  ✓" or ""), callback = function() pick(false) end }}
    end
    local row = {}
    for _i, name in ipairs(M.names()) do
        row[#row + 1] = { text = M.label(name) .. (name == current and "  ✓" or ""), callback = function() pick(name) end }
        if #row == 2 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    buttons[#buttons + 1] = {
        { text = _("New collection…"), callback = function()
            UIManager:close(dialog)
            askNew(on_done)
        end },
        { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
    }
    dialog = ButtonDialog:new{ title = opts.title or _("Add downloads to which collection?"), buttons = buttons }
    UIManager:show(dialog)
end

--- Button text: "Collection: Fantasy" or "Collection: none".
function M.buttonText(name)
    return name and T(_("Collection: %1"), M.label(name)) or _("Collection: none")
end

return M
