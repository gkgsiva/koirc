--[[--
Where a book file is, and moving it to another folder.

Moving keeps everything pointing at the book: KOReader's reading progress
and highlights (the .sdr folder), its history and collections, the
Hardcover book the file is attached to, the collections this plugin
manages, and the download history.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local Relocate = require("koirc/relocate")

local M = {}

local function isFile(p) return p ~= nil and lfs.attributes(p, "mode") == "file" end
local function isDir(p) return p ~= nil and lfs.attributes(p, "mode") == "directory" end
local function exists(p) return lfs.attributes(p, "mode") ~= nil end

local function sizeText(path)
    local size = lfs.attributes(path, "size")
    if not size then return nil end
    if size >= 1048576 then return string.format("%.1f MB", size / 1048576) end
    return string.format("%d KB", math.max(1, math.floor(size / 1024 + 0.5)))
end

--- Copy, for a move to another file system (an SD card), where os.rename
-- fails. Removes a partial copy.
local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local dst = io.open(to, "wb")
    if not dst then src:close() return false end
    local ok = true
    while true do
        local chunk = src:read(1048576)
        if not chunk then break end
        if not dst:write(chunk) then ok = false break end
    end
    src:close()
    dst:close()
    if ok and lfs.attributes(to, "size") ~= lfs.attributes(from, "size") then ok = false end
    if not ok then os.remove(to) end
    return ok
end

--- True when path is the book open in the reader.
local function isOpen(plugin, path)
    local doc = plugin and plugin.ui and plugin.ui.document
    return doc ~= nil and doc.file == path
end

--- Point the plugin's own records at the new path. batch (optional): moving
-- several files; the history file is written once, by M.finishBatch.
function M.relink(plugin, old, new, batch)
    local s = plugin.settings
    Relocate.replaceValues(s.hardcover_files, old, new)
    plugin:saveSettings()
    local hc = plugin.hardcover
    if hc then
        pcall(function()
            local managed = hc:storeValue("collections")
            if Relocate.managed(managed, old, new) > 0 then hc:setStoreValue("collections", managed) end
        end)
        pcall(function() hc:renameFile(old, new) end)
    end
    pcall(function()
        local H = require("historyui")
        if Relocate.history(H.list(), old, new) > 0 then
            if batch then batch.history = true else H.save() end
        end
        H.renamed(old, new)
    end)
    if not batch then pcall(function() require("storage").forget() end) end
end

--- After moving several files with a batch: write what was put off.
function M.finishBatch(plugin, batch)
    if batch and batch.history then
        pcall(function() require("historyui").save() end)
        batch.history = nil
    end
    pcall(function() require("storage").forget() end)
    M.refreshFileBrowser()
end

--- Move the book file at old into dir. Returns the new path, or nil and
-- a message. batch (optional): see relink; call finishBatch at the end.
function M.move(plugin, old, dir, batch)
    if not isFile(old) then return nil, _("The file is no longer on the device.") end
    dir = Relocate.cleanDir(dir)
    if not isDir(dir) then return nil, T(_("The folder does not exist:\n%1"), dir) end
    if Relocate.sameDir(old, dir) then return old end
    if isOpen(plugin, old) then
        return nil, _("This book is open. Close it first, then move it from the file browser or the Hardcover view.")
    end
    local _d, name = Relocate.split(old)
    local target = Relocate.target(dir, name, exists)
    -- KOReader's collections know the file by its real path; ask before
    -- the file is gone.
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    local real_old = ok_ffi and ffiutil.realpath and ffiutil.realpath(old) or old
    if not os.rename(old, target) then
        if not copyFile(old, target) then
            return nil, T(_("Could not move the file to:\n%1"), dir)
        end
        local removed, err = os.remove(old)
        if not removed then logger.warn("ircbooks: moved file, but could not remove the old copy:", old, err) end
    end
    logger.info("ircbooks: moved", old, "to", target)
    -- Reading progress, highlights, custom cover and metadata.
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings.updateLocation then DocSettings.updateLocation(old, target) end
    end)
    pcall(function()
        local ReadHistory = require("readhistory")
        if ReadHistory.updateItem then ReadHistory:updateItem(old, target) end
    end)
    pcall(function()
        local ReadCollection = require("readcollection")
        if ReadCollection.updateItem and ReadCollection.addCollection then
            ReadCollection:updateItem(real_old, target)
        end
    end)
    M.relink(plugin, old, target, batch)
    if not batch then M.refreshFileBrowser() end
    return target
end

function M.refreshFileBrowser()
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
end

--- Pick a folder and move the file there. on_moved(new_path) after a move.
function M.chooseAndMove(plugin, path, on_moved)
    if isOpen(plugin, path) then
        UIManager:show(InfoMessage:new{ text = _("This book is open. Close it first, then move it from the file browser or the Hardcover view.") })
        return
    end
    local dir, name = Relocate.split(path)
    require("folderpicker").choose(dir or plugin:getDownloadDir(), function(dest)
        if Relocate.sameDir(path, dest) then
            UIManager:show(InfoMessage:new{ text = _("The book is already in this folder."), timeout = 3 })
            return
        end
        local new_path, err = M.move(plugin, path, dest)
        if not new_path then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end
        UIManager:show(InfoMessage:new{ text = T(_("Moved to:\n%1"), new_path), timeout = 3 })
        if on_moved then on_moved(new_path) end
    end, {
        title = T(_("Move “%1”: long-press a folder"), name or path),
        confirm_text = _("Move the book to this folder?\n\n%1"),
        ok_text = _("Move here"),
    })
end

--- Show the file's folder in the file browser. before(): close the
-- plugin's screens first. In the reader, only says where the file is: the
-- book stays open.
function M.showInFileBrowser(plugin, path, before)
    local dir = Relocate.split(path)
    local function tell()
        UIManager:show(InfoMessage:new{ text = T(_("The file is in this folder:\n%1"), dir or path) })
    end
    if not dir or (plugin.ui and plugin.ui.document) then return tell() end
    local ok, err = pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if before then before() end
        if fm and fm.file_chooser and fm.file_chooser.changeToPath then
            fm.file_chooser:changeToPath(dir, path)
        else
            FileManager:showFiles(dir, path)
        end
    end)
    if not ok then
        logger.warn("ircbooks: could not show the folder:", err)
        tell()
    end
end

--- A dialog with the file's folder, name and size, and buttons to show it
-- in the file browser or move it. before(): close the plugin's screens
-- before the file browser is shown. on_moved(new_path).
function M.showLocation(plugin, path, before, on_moved)
    if not isFile(path) then
        UIManager:show(InfoMessage:new{ text = _("The file is no longer on the device.") })
        return
    end
    local dir, name = Relocate.split(path)
    local lines = { T(_("Folder:\n%1"), dir or "?"), "", T(_("File:\n%1"), name or path) }
    local size = sizeText(path)
    if size then lines[#lines + 1] = "" lines[#lines + 1] = T(_("Size: %1"), size) end
    local dialog
    local reading = plugin.ui and plugin.ui.document ~= nil
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "left",
        buttons = {
            {
                {
                    text = _("Show in file browser"),
                    enabled = not reading,
                    callback = function()
                        UIManager:close(dialog)
                        M.showInFileBrowser(plugin, path, before)
                    end,
                },
                {
                    text = _("Move to another folder…"),
                    enabled = not isOpen(plugin, path),
                    callback = function()
                        UIManager:close(dialog)
                        M.chooseAndMove(plugin, path, on_moved)
                    end,
                },
            },
            {{ text = _("Close"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

return M
