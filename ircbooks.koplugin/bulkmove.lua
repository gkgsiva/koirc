--[[--
Move or re-file several books at once: pick books from a folder, the
download history or the books attached to Hardcover, tick the ones to move,
then move them to a folder or file them in author / series folders.

Each file is moved with filemove.lua, so reading progress, highlights,
KOReader history and collections, attached Hardcover books, the plugin's
collections and the download history follow it. The open book is skipped.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local Hardcover = require("koirc/hardcover")
local Relocate = require("koirc/relocate")

local M = {}

-- Book files looked at in one folder (with its subfolders) at most.
M.MAX_FILES = 3000
local MAX_DEPTH = 4

local BOOK_EXTS = {
    epub = true, mobi = true, azw = true, azw3 = true, pdf = true, fb2 = true, djvu = true,
    txt = true, rtf = true, doc = true, docx = true, cbz = true, cbr = true, prc = true,
    pdb = true, lit = true, htm = true, html = true, kepub = true, zip = true,
}

local MODES = {
    { id = "author", name = _("a folder per author") },
    { id = "series", name = _("a folder per series") },
    { id = "author_series", name = _("author, then series folders") },
}

local function isFile(p) return p and lfs.attributes(p, "mode") == "file" end

--- Book files under dir.
local function scanFolder(dir)
    local out = {}
    local function walk(d, depth)
        if #out >= M.MAX_FILES then return end
        local ok, iter, obj = pcall(lfs.dir, d)
        if not ok then return end
        local subdirs = {}
        for name in iter, obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local p = d .. "/" .. name
                local mode = lfs.attributes(p, "mode")
                if mode == "directory" then
                    if not name:match("%.sdr$") then subdirs[#subdirs + 1] = p end
                elseif mode == "file" then
                    local ext = name:match("%.([%w]+)$")
                    if ext and BOOK_EXTS[ext:lower()] then out[#out + 1] = { path = p } end
                end
            end
        end
        if depth < MAX_DEPTH then
            table.sort(subdirs)
            for _i, sd in ipairs(subdirs) do walk(sd, depth + 1) end
        end
    end
    walk(Relocate.cleanDir(dir), 1)
    table.sort(out, function(a, b) return a.path:lower() < b.path:lower() end)
    return out
end

--- Author and series of a file: the attached Hardcover book, else
-- KOReader's book info, else the file name.
local function infoFor(plugin, path, attached)
    local book = attached and attached[path]
    if book then return book end
    local info
    pcall(function()
        local DocSettings = require("docsettings")
        local ds = DocSettings:open(path)
        local props = ds and ds:readSetting("doc_props")
        if type(props) == "table" and (props.authors or props.series) then
            info = {
                title = props.title,
                author = props.authors and tostring(props.authors):match("^[^\n]+"),
                series = props.series,
            }
        end
    end)
    if not info then
        pcall(function()
            local BIM = package.loaded["bookinfomanager"]
            local bi = BIM and BIM.getBookInfo and BIM:getBookInfo(path, false)
            if type(bi) == "table" and (bi.authors or bi.series) then
                info = { title = bi.title, author = bi.authors and tostring(bi.authors):match("^[^\n]+"), series = bi.series }
            end
        end)
    end
    if not info then
        local name = path:match("([^/]+)$") or path
        info = Hardcover.entryBook({ title = name })
    end
    return info
end

--- path -> attached Hardcover book.
local function attachedBooks(plugin)
    local by_path = {}
    pcall(function()
        local by_id = plugin.hardcover:booksById()
        for id, p in pairs(plugin.settings.hardcover_files or {}) do
            if p and by_id[id] then by_path[p] = by_id[id] end
        end
    end)
    return by_path
end

local function nameOf(f)
    local dir, name = Relocate.split(f.path)
    return name or f.path, dir
end

--- Do the moves in plan ({path, dir}) and report.
local function run(plugin, plan, after)
    if #plan == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing to move: the books are in place already."), timeout = 3 })
        return
    end
    local wait = InfoMessage:new{ text = T(_("Moving %1 books…"), #plan) }
    UIManager:show(wait)
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.1, function()
        local FileMove = require("filemove")
        local batch = {}
        local moved, failed = 0, {}
        local util = require("util")
        for _i, step in ipairs(plan) do
            pcall(function() util.makePath(step.dir) end)
            local ok, new_path, err = pcall(FileMove.move, plugin, step.path, step.dir, batch)
            if ok and new_path then
                moved = moved + 1
            else
                failed[#failed + 1] = T("%1: %2", (step.path:match("([^/]+)$")), tostring(ok and err or new_path))
            end
        end
        FileMove.finishBatch(plugin, batch)
        UIManager:close(wait)
        local lines = { T(_("Moved %1 of %2 books."), moved, #plan) }
        if #failed > 0 then
            lines[#lines + 1] = ""
            for i = 1, math.min(#failed, 8) do lines[#lines + 1] = "✗ " .. failed[i] end
        end
        logger.info("ircbooks: bulk move:", moved, "moved,", #failed, "failed")
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
        if after then after() end
    end)
end

local function chooseFolder(plugin, title, on_done)
    require("folderpicker").choose(plugin:getDownloadDir(), on_done, {
        title = title,
        confirm_text = _("Use this folder?\n\n%1"),
        ok_text = _("Use this folder"),
    })
end

--- The actions for the selected books.
local function act(plugin, selected, after)
    local dialog
    local n = #selected
    local buttons = {
        {{
            text = T(_("Move %1 books to a folder…"), n),
            callback = function()
                UIManager:close(dialog)
                chooseFolder(plugin, T(_("Move %1 books: long-press a folder"), n), function(dir)
                    run(plugin, Relocate.plan(selected, dir), after)
                end)
            end,
        }},
    }
    for _i, m in ipairs(MODES) do
        buttons[#buttons + 1] = {{
            text = T(_("File them in %1…"), m.name),
            callback = function()
                UIManager:close(dialog)
                chooseFolder(plugin, T(_("File %1 books under: long-press a folder"), n), function(root)
                    local attached = attachedBooks(plugin)
                    local files = {}
                    for _j, f in ipairs(selected) do
                        files[#files + 1] = { path = f.path, info = f.info or infoFor(plugin, f.path, attached) }
                    end
                    local plan = Relocate.plan(files, root, m.id)
                    -- Say what will happen first: a wrong guess moves many files.
                    local lines = {}
                    for k = 1, math.min(#plan, 6) do
                        local p = plan[k]
                        lines[#lines + 1] = "• " .. (p.path:match("([^/]+)$")) .. "\n   → " .. p.dir
                    end
                    if #plan > 6 then lines[#lines + 1] = T(_("…and %1 more"), #plan - 6) end
                    UIManager:show(require("ui/widget/confirmbox"):new{
                        text = T(_("File %1 books?\n\n%2"), #plan, table.concat(lines, "\n")),
                        ok_text = _("Move"),
                        ok_callback = function() run(plugin, plan, after) end,
                    })
                end)
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{ title = T(_("%1 books selected"), n), buttons = buttons }
    UIManager:show(dialog)
end

--- The list to tick books in. files: array of {path, info}.
function M.select(plugin, files, title)
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = _("No book files found there.") })
        return
    end
    local sel = {}
    local menu
    local function count()
        local n = 0
        for _k in pairs(sel) do n = n + 1 end
        return n
    end
    local function items()
        local n = count()
        local list = {
            {
                text = n > 0 and T(_("Move or file %1 selected…"), n) or _("Tap books to select them"),
                act = n > 0 or nil,
                bold = true,
            },
            {
                text = n == #files and _("Select none") or T(_("Select all %1"), #files),
                all = true,
                separator = true,
            },
        }
        for _i, f in ipairs(files) do
            local name, dir = nameOf(f)
            list[#list + 1] = { text = (sel[f] and "☑ " or "☐ ") .. name, mandatory = dir and dir:match("([^/]+)$") or "", file = f }
        end
        return list
    end
    local function redraw(keep_page)
        local page = keep_page and menu.page
        menu:switchItemTable(title, items())
        if page and page > 1 and menu.page_num and page <= menu.page_num and menu.onGotoPage then
            pcall(menu.onGotoPage, menu, page)
        end
    end
    menu = plugin.hardcover:makeMenu{
        title = title,
        items = items(),
        on_select = function(item)
            if item.act then
                local chosen = {}
                for _i, f in ipairs(files) do
                    if sel[f] then chosen[#chosen + 1] = f end
                end
                act(plugin, chosen, function()
                    UIManager:close(menu)
                    pcall(function() plugin.hardcover:refreshBooksSoon() end)
                end)
            elseif item.all then
                if count() == #files then sel = {} else for _i, f in ipairs(files) do sel[f] = true end end
                redraw(true)
            elseif item.file then
                sel[item.file] = not sel[item.file] or nil
                -- Only this page changes: redraw it, not the whole list.
                local name = nameOf(item.file)
                item.text = (sel[item.file] and "☑ " or "☐ ") .. name
                local n = count()
                local head = menu.item_table and menu.item_table[1]
                if head then
                    head.text = n > 0 and T(_("Move or file %1 selected…"), n) or _("Tap books to select them")
                    head.act = n > 0 or nil
                end
                if not (menu.updateItems and pcall(menu.updateItems, menu, 1, true)) then redraw(true) end
            end
        end,
    }
    UIManager:show(menu)
end

--- Start: where to pick the books from.
function M.start(plugin)
    local dialog
    local function close() UIManager:close(dialog) end
    dialog = ButtonDialog:new{
        title = _("Move or re-file books\n\nPick the books from:"),
        title_align = "left",
        buttons = {
            {{
                text = _("A folder (with its subfolders)…"),
                callback = function()
                    close()
                    chooseFolder(plugin, _("Books from: long-press a folder"), function(dir)
                        M.select(plugin, scanFolder(dir), dir:match("([^/]+)$") or dir)
                    end)
                end,
            }},
            {{
                text = _("Download history"),
                callback = function()
                    close()
                    local files, seen = {}, {}
                    for _i, r in ipairs(require("historyui").list()) do
                        if r.path and not seen[r.path] and isFile(r.path) then
                            seen[r.path] = true
                            -- Author and series are looked up when filing (the
                            -- record has no series).
                            files[#files + 1] = { path = r.path }
                        end
                    end
                    M.select(plugin, files, _("Downloaded books"))
                end,
            }},
            {{
                text = _("Books attached to Hardcover"),
                callback = function()
                    close()
                    local files = {}
                    for path, book in pairs(attachedBooks(plugin)) do
                        if isFile(path) then files[#files + 1] = { path = path, info = book } end
                    end
                    table.sort(files, function(a, b) return a.path:lower() < b.path:lower() end)
                    M.select(plugin, files, _("Attached books"))
                end,
            }},
            {{ text = _("Cancel"), callback = close }},
        },
    }
    UIManager:show(dialog)
end

M._scanFolder = scanFolder

return M
