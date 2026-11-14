--[[--
Storage guard: before a download, check the free space where the book will
be saved. When it is low, warn and offer to clean up finished books first.

The free space is read with KOReader's util.diskUsage (or df) and kept for a
short while, so a list of downloads does not run df for every book.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local results = require("koirc/results")

local M = {}

-- Warn when less than this much would be left after the download (MB).
M.DEFAULT_MIN_MB = 100
local CACHE_TTL = 60
local cache = { dir = nil, at = 0, free = nil }

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Free bytes on the file system holding dir, or nil when unknown.
function M.freeBytes(dir)
    if cache.dir == dir and os.time() - cache.at < CACHE_TTL then return cache.free end
    local free
    local ok, util = pcall(require, "util")
    if ok and util.diskUsage then
        local uok, usage = pcall(util.diskUsage, dir)
        if uok and type(usage) == "table" and tonumber(usage.available) then free = tonumber(usage.available) end
    end
    if not free then
        pcall(function()
            local p = io.popen("df -k " .. shellQuote(dir) .. " 2>/dev/null")
            if not p then return end
            local out = p:read("*a") or ""
            p:close()
            -- Last line: Filesystem 1K-blocks Used Available Use% Mounted
            local last
            for line in out:gmatch("[^\n]+") do last = line end
            local avail = last and last:match("^%S*%s+%d+%s+%d+%s+(%d+)")
            if not avail and last then avail = last:match("^%s*%d+%s+%d+%s+(%d+)") end -- wrapped line
            if avail then free = tonumber(avail) * 1024 end
        end)
    end
    cache.dir, cache.at, cache.free = dir, os.time(), free
    return free
end

--- Read the free space again next time (after a download or cleanup).
function M.forget()
    cache.at = 0
end

local function minBytes(plugin)
    local mb = tonumber(plugin.settings.min_free_mb)
    if mb == nil then mb = M.DEFAULT_MIN_MB end
    return mb * 1048576
end

local function mb(n)
    return string.format("%.0f MB", (n or 0) / 1048576)
end

--- Would there still be enough room after downloading entry? Returns true
-- when there is (or when the free space can't be read), else false, free.
function M.hasRoom(plugin, entry)
    local min = minBytes(plugin)
    if min <= 0 then return true end
    local free = M.freeBytes(plugin:getDownloadDir())
    if not free then return true end
    local size = entry and results.sizeBytes(entry.size) or 0
    if free - size < min then return false, free end
    return true, free
end

--- Run go() now when there is room; otherwise ask first, offering to clean
-- up finished books (and to check again afterwards).
function M.guard(plugin, entry, go)
    local ok, free = M.hasRoom(plugin, entry)
    if ok then return go() end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("The device is nearly full: %1 free.\n\nDelete or archive finished books first?"), mb(free)),
        title_align = "left",
        buttons = {
            {
                { text = _("Clean up finished books…"), callback = function()
                    UIManager:close(dialog)
                    require("cleanup").new(plugin, {
                        on_close = function()
                            M.forget()
                            if M.hasRoom(plugin, entry) then
                                UIManager:show(InfoMessage:new{ text = _("There is enough room now."), timeout = 2 })
                                go()
                            else
                                M.guard(plugin, entry, go)
                            end
                        end,
                    }):show()
                end },
            },
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Download anyway"), callback = function()
                    UIManager:close(dialog)
                    go()
                end },
            },
        },
    }
    UIManager:show(dialog)
end

function M.getSettingsItem(plugin)
    return {
        text_func = function()
            local v = tonumber(plugin.settings.min_free_mb) or M.DEFAULT_MIN_MB
            if v <= 0 then return _("Warn when storage is low: off") end
            return T(_("Warn when less than %1 MB would be free"), v)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local dialog
            dialog = InputDialog:new{
                title = _("Warn before downloading when less than this many MB would be free (0 = never)"),
                input = tostring(tonumber(plugin.settings.min_free_mb) or M.DEFAULT_MIN_MB),
                input_type = "number",
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                    { text = _("Save"), is_enter_default = true, callback = function()
                        local v = tonumber(dialog:getInputText())
                        UIManager:close(dialog)
                        if not v or v < 0 then return end
                        plugin.settings.min_free_mb = math.floor(v)
                        plugin:saveSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    }
end

return M
