--[[--
Export and import of book lists (koirc/listfile.lua): Want to read,
followed series, saved Hardcover lists and followed authors in one JSON
file in the download folder. An imported file (or a plain text file with
one "Author - Title" per line) can be downloaded in the background, added
to Want to read on Hardcover, and its authors followed.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local Follows = require("koirc/follows")
local Hardcover = require("koirc/hardcover")
local ListFile = require("koirc/listfile")

local M = {}

local function json(plugin)
    return plugin.hardcover.json
end

--- What to export, from the saved Hardcover data.
function M.gather(plugin)
    local hc = plugin.hardcover
    local cache = hc:cache()
    local want = cache["books:status:" .. tostring(Hardcover.STATUS_WANT_TO_READ)]
    local series = {}
    local tracker = type(cache.series) == "table" and cache.series.following or {}
    for _i, sr in ipairs(tracker) do
        series[#series + 1] = { id = sr.id, name = sr.name, books = cache["books:series:" .. tostring(sr.id)] }
    end
    local lists = {}
    for _i, l in ipairs(type(cache.lists) == "table" and cache.lists.lists or {}) do
        lists[#lists + 1] = { id = l.id, name = l.name, books = cache["books:list:" .. tostring(l.id)] }
    end
    local authors = {}
    for _i, a in ipairs(require("authorsui").all(plugin)) do authors[#authors + 1] = { name = a.name, id = a.id } end
    return { want = type(want) == "table" and want or {}, series = series, lists = lists, authors = authors, now = os.time() }
end

function M.export(plugin)
    local hc = plugin.hardcover
    if not json(plugin) then
        UIManager:show(InfoMessage:new{ text = _("This KOReader version has no JSON module.") })
        return
    end
    local function write()
        local ok, res = pcall(function()
            local text = ListFile.encode(json(plugin), M.gather(plugin))
            local path = string.format("%s/%s-%s.json", plugin:getDownloadDir(), ListFile.PREFIX, os.date("%Y-%m-%d"))
            local f = assert(io.open(path, "wb"))
            f:write(text)
            f:close()
            return path
        end)
        if not ok then
            logger.err("ircbooks: list export failed:", res)
            UIManager:show(InfoMessage:new{ text = T(_("Could not export the lists:\n%1"), tostring(res)) })
            return
        end
        local d = ListFile.parse(json(plugin), (function()
            local f = io.open(res, "rb")
            local t = f and f:read("*a") or ""
            if f then f:close() end
            return t
        end)())
        UIManager:show(InfoMessage:new{
            text = T(_("Lists saved to:\n%1\n\n%2\n\nSeries and lists hold the books saved at the last sync."),
                res, d and ListFile.summary(d) or ""),
        })
    end
    -- Want to read may not be saved yet (it is loaded when opened).
    local key = "books:status:" .. tostring(Hardcover.STATUS_WANT_TO_READ)
    if hc:hasToken() and not hc:cache()[key] then
        local data = hc:fetch(key, _("Loading Want to read…"), function() M.export(plugin) end)
        if not data then return end
    end
    write()
end

local function readText(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

--- Books of the file that are not on the device.
local function missing(plugin, books)
    local hc = plugin.hardcover
    local files = hc:localFiles() or {}
    local out = {}
    for _i, b in ipairs(books) do
        local have
        if b.id then
            have = hc:localFile(b)
        else
            have = Hardcover.findFile(b, files)
        end
        if not have then out[#out + 1] = b end
    end
    return out
end

function M.showImport(plugin, d, path)
    local hc = plugin.hardcover
    local dialog
    local function close() UIManager:close(dialog) end
    local function queueBooks(which, name)
        close()
        local books = missing(plugin, ListFile.allBooks(d, which))
        if #books == 0 then
            UIManager:show(InfoMessage:new{ text = _("Every book of it is on the device already.") })
            return
        end
        plugin:startQueue(books, name)
    end
    local buttons = {}
    local want = #(d.want_to_read or {})
    if want > 0 then
        buttons[#buttons + 1] = {{
            text = T(_("Download missing Want to read books (%1)"), want),
            callback = function() queueBooks("want", _("Imported Want to read")) end,
        }}
    end
    local series_books = #ListFile.allBooks(d, "series")
    if series_books > 0 then
        buttons[#buttons + 1] = {{
            text = T(_("Download missing series books (%1)"), series_books),
            callback = function() queueBooks("series", _("Imported series")) end,
        }}
    end
    local list_books = #ListFile.allBooks(d, "lists")
    if list_books > 0 then
        buttons[#buttons + 1] = {{
            text = T(_("Download missing list books (%1)"), list_books),
            callback = function() queueBooks("lists", _("Imported lists")) end,
        }}
    end
    local with_id = {}
    for _i, b in ipairs(d.want_to_read or {}) do if b.id then with_id[#with_id + 1] = b end end
    if #with_id > 0 and hc:hasToken() then
        buttons[#buttons + 1] = {{
            text = T(_("Add to Want to read on Hardcover (%1)"), #with_id),
            callback = function()
                close()
                -- Sent in the background; books on another shelf stay there.
                for _i, b in ipairs(with_id) do hc:queueStatus(b, Hardcover.STATUS_WANT_TO_READ) end
                UIManager:show(InfoMessage:new{
                    text = T(_("%1 books will be added to Want to read on Hardcover in the background. Books already on one of your shelves stay where they are."), #with_id),
                })
            end,
        }}
    end
    if #(d.authors or {}) > 0 then
        buttons[#buttons + 1] = {{
            text = T(_("Follow the %1 authors"), #d.authors),
            callback = function()
                close()
                local n = 0
                for _i, a in ipairs(d.authors) do
                    local e, new = Follows.add(plugin.settings, a.name, a.id)
                    if e and new then n = n + 1 end
                end
                plugin:saveSettings()
                UIManager:show(InfoMessage:new{ text = T(_("Now following %1 more authors."), n), timeout = 3 })
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = close }}
    local title = T(_("Book lists from:\n%1\n\n%2"), path:match("([^/]+)$") or path, ListFile.summary(d))
    if d.exported then title = title .. "\n" .. T(_("Exported %1"), d.exported:sub(1, 10)) end
    dialog = ButtonDialog:new{ title = title, title_align = "left", buttons = buttons }
    UIManager:show(dialog)
end

function M.import(plugin)
    if not json(plugin) then
        UIManager:show(InfoMessage:new{ text = _("This KOReader version has no JSON module.") })
        return
    end
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        title = _("Choose a book list file (.json or .txt)"),
        select_directory = false,
        select_file = true,
        show_files = true,
        path = plugin:getDownloadDir(),
        file_filter = function(name) return name:match("%.json$") ~= nil or name:match("%.txt$") ~= nil end,
        onConfirm = function(path)
            local d, err = ListFile.parse(json(plugin), readText(path) or "")
            if not d then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            M.showImport(plugin, d, path)
        end,
    })
end

return M
