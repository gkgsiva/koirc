--[[--
Storage cleanup: list the finished books on the device and archive (move to
an Archive folder) or delete them, one by one or all at once.

A book counts as finished when KOReader marks it finished (or it was read to
the end), or when this plugin marked it as Read on Hardcover.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Hardcover = require("koirc/hardcover")

local Cleanup = {}
Cleanup.__index = Cleanup

local function isFile(p) return p and lfs.attributes(p, "mode") == "file" end

local function fileName(p) return p:match("([^/]+)$") or p end

local function dirName(p) return p:match("^(.*)/[^/]+$") or "." end

function Cleanup.new(plugin)
    return setmetatable({ plugin = plugin }, Cleanup)
end

function Cleanup:settings() return self.plugin.settings end

function Cleanup:archiveDir()
    local d = self:settings().archive_dir
    if d and d ~= "" then return d end
    return self.plugin:getDownloadDir() .. "/Archive"
end

local function finishedInKOReader(path)
    local DocSettings = require("docsettings")
    if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(path) then return false end
    local ds = DocSettings:open(path)
    local summary = ds:readSetting("summary")
    if type(summary) == "table" and summary.status == "complete" then return true end
    return (tonumber(ds:readSetting("percent_finished")) or 0) >= 0.995
end

--- Finished book files: array of {path, why}.
function Cleanup:findFinished()
    local s = self:settings()
    local archive = self:archiveDir()
    local open = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
    local out, seen = {}, {}
    local function add(path, why)
        if not path or seen[path] or path == open or not isFile(path) then return end
        if path:sub(1, #archive + 1) == archive .. "/" then return end
        seen[path] = true
        out[#out + 1] = { path = path, why = why }
    end
    -- Books Hardcover has as Read (marked by this plugin).
    local sent = s.hardcover_status_sent or {}
    for key, path in pairs(s.hardcover_files or {}) do
        if path and sent[key] == Hardcover.STATUS_READ then add(path, _("Read on Hardcover")) end
    end
    -- Books in KOReader's history that it has as finished.
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and type(ReadHistory.hist) == "table" then
        for _i, item in ipairs(ReadHistory.hist) do
            local path = type(item) == "table" and item.file
            if path and not seen[path] and isFile(path) then
                local fok, finished = pcall(finishedInKOReader, path)
                if fok and finished then add(path, _("finished")) end
            end
        end
    end
    table.sort(out, function(a, b) return fileName(a.path):lower() < fileName(b.path):lower() end)
    return out
end

--- Point Hardcover attachments at the new path (or drop them).
function Cleanup:relink(old, new)
    local files = self:settings().hardcover_files
    if type(files) ~= "table" then return end
    for key, p in pairs(files) do
        if p == old then files[key] = new end
    end
end

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local dst = io.open(to, "wb")
    if not dst then src:close() return false end
    while true do
        local chunk = src:read(1048576)
        if not chunk then break end
        dst:write(chunk)
    end
    src:close()
    dst:close()
    return true
end

function Cleanup:archive(path)
    local util = require("util")
    local dir = self:archiveDir()
    util.makePath(dir)
    local name = fileName(path)
    local target = dir .. "/" .. name
    local base, ext = name:match("^(.*)(%.[^.]+)$")
    local n = 2
    while lfs.attributes(target, "mode") do
        target = dir .. "/" .. (base or name) .. " (" .. n .. ")" .. (ext or "")
        n = n + 1
    end
    local ok = os.rename(path, target)
    if not ok then
        -- Another filesystem (e.g. an SD card): copy, then remove.
        if not copyFile(path, target) then return nil, T(_("Could not move %1"), name) end
        os.remove(path)
    end
    local DocSettings = require("docsettings")
    if DocSettings.updateLocation then pcall(DocSettings.updateLocation, path, target) end
    local hok, ReadHistory = pcall(require, "readhistory")
    if hok and ReadHistory.updateItem then pcall(ReadHistory.updateItem, ReadHistory, path, target) end
    self:relink(path, target)
    return target
end

function Cleanup:delete(path)
    local ok, err = os.remove(path)
    if not ok then return nil, tostring(err) end
    pcall(function()
        local DocSettings = require("docsettings")
        DocSettings:open(path):purge()
    end)
    local hok, ReadHistory = pcall(require, "readhistory")
    if hok and ReadHistory.fileDeleted then pcall(ReadHistory.fileDeleted, ReadHistory, path) end
    local BookInfoManager = package.loaded["bookinfomanager"]
    if type(BookInfoManager) == "table" and BookInfoManager.deleteBookInfo then
        pcall(BookInfoManager.deleteBookInfo, BookInfoManager, path)
    end
    self:relink(path, nil)
    return true
end

--- Run fn on each path, then report.
function Cleanup:applyAll(books, fn, verb)
    local done, failed = 0, 0
    for _i, b in ipairs(books) do
        local ok, res, err = pcall(fn, self, b.path)
        if ok and res then
            done = done + 1
        else
            failed = failed + 1
            logger.warn("ircbooks: cleanup failed for", b.path, ok and err or res)
        end
    end
    self.plugin:saveSettings()
    local text = T(_("%1 %2."), verb, done)
    if failed > 0 then text = text .. "\n" .. T(_("%1 could not be changed."), failed) end
    UIManager:show(InfoMessage:new{ text = text, timeout = failed > 0 and nil or 3 })
    self:refresh()
end

function Cleanup:show()
    local msg = InfoMessage:new{ text = _("Looking for finished books…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, books = pcall(function() return self:findFinished() end)
    UIManager:close(msg)
    if not ok then
        logger.err("ircbooks: finding finished books failed:", books)
        UIManager:show(InfoMessage:new{ text = tostring(books) })
        return
    end
    self.books = books
    if self.menu then UIManager:close(self.menu) end
    self.menu = Menu:new{
        title = _("Finished books"),
        item_table = self:items(),
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        multilines_show_more_text = true,
        multilines_forced = true,
        items_max_lines = 3,
        items_per_page = 8,
        onMenuSelect = function(_m, item) self:onSelect(item) return true end,
        close_callback = function()
            if self.menu then UIManager:close(self.menu) end
            self.menu = nil
        end,
    }
    UIManager:show(self.menu)
end

function Cleanup:refresh()
    if not self.menu then return end
    local ok, books = pcall(function() return self:findFinished() end)
    self.books = ok and books or {}
    self.menu:switchItemTable(_("Finished books"), self:items(), -1)
end

function Cleanup:items()
    local books = self.books or {}
    local items = {}
    if #books == 0 then
        items[1] = { text = _("No finished books on the device."), dim = true }
    else
        items[#items + 1] = { text = T(_("Archive all (%1)"), #books), all = "archive", bold = true }
        items[#items + 1] = { text = T(_("Delete all (%1)…"), #books), all = "delete", bold = true }
    end
    items[#items + 1] = {
        text = T(_("Archive folder: %1"), self:archiveDir()),
        pick_dir = true,
        separator = true,
    }
    for _i, b in ipairs(books) do
        items[#items + 1] = { text = fileName(b.path), mandatory = b.why, book = b }
    end
    return items
end

function Cleanup:onSelect(item)
    if item.pick_dir then
        local PathChooser = require("ui/widget/pathchooser")
        UIManager:show(PathChooser:new{
            title = _("Choose the archive folder"),
            select_directory = true,
            select_file = false,
            path = dirName(self:archiveDir()),
            onConfirm = function(path)
                self:settings().archive_dir = path
                self.plugin:saveSettings()
                self:refresh()
            end,
        })
    elseif item.all == "archive" then
        UIManager:show(ConfirmBox:new{
            text = T(_("Move %1 finished books to\n%2?"), #self.books, self:archiveDir()),
            ok_text = _("Archive"),
            ok_callback = function() self:applyAll(self.books, Cleanup.archive, _("Archived")) end,
        })
    elseif item.all == "delete" then
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete %1 finished books from the device? This cannot be undone."), #self.books),
            ok_text = _("Delete"),
            ok_callback = function() self:applyAll(self.books, Cleanup.delete, _("Deleted")) end,
        })
    elseif item.book then
        self:showBook(item.book)
    end
end

function Cleanup:showBook(b)
    local dialog
    local function run(fn, verb)
        UIManager:close(dialog)
        self:applyAll({ b }, fn, verb)
    end
    dialog = ButtonDialog:new{
        title = T(_("%1\n\nIn %2"), fileName(b.path), dirName(b.path)),
        title_align = "left",
        buttons = {
            { { text = _("Archive"), callback = function() run(Cleanup.archive, _("Archived")) end },
              { text = _("Delete"), callback = function()
                  UIManager:close(dialog)
                  UIManager:show(ConfirmBox:new{
                      text = T(_("Delete %1? This cannot be undone."), fileName(b.path)),
                      ok_text = _("Delete"),
                      ok_callback = function() self:applyAll({ b }, Cleanup.delete, _("Deleted")) end,
                  })
              end } },
            { { text = _("Open"), callback = function()
                  UIManager:close(dialog)
                  if self.menu then UIManager:close(self.menu) self.menu = nil end
                  self.plugin:openBook(b.path)
              end },
              { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

return Cleanup
