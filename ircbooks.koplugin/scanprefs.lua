--[[--
Settings → "Folders to skip when looking for books": big folders such as
comics, manga or PDF collections that the plugin should not walk through
when it looks for your books (Hardcover matching, "Scan for new books",
collections). Skipping them makes those scans shorter on e-ink devices.

Stored in settings.scan_skip: folder paths ("/mnt/us/documents/Comics") and
plain folder names skipped anywhere ("Comics"). See Hardcover.skipper.
]]

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function list(plugin)
    local l = plugin.settings.scan_skip
    if type(l) ~= "table" then
        l = {}
        plugin.settings.scan_skip = l
    end
    return l
end

local function changed(plugin, tm)
    plugin:saveSettings()
    -- The next lookup scans again without the skipped folders.
    pcall(function() plugin.hardcover:forgetFiles() end)
    if not tm then return end
    -- The entries are built when the menu opens: rebuild them in place, if
    -- this menu is still the one shown.
    local t = tm.item_table
    if type(t) == "table" and t[1] and t[1].scan_skip_menu then
        local fresh = M.items(plugin)
        for k = #t, 1, -1 do t[k] = nil end
        for k, it in ipairs(fresh) do t[k] = it end
    end
    tm:updateItems()
end

local function add(plugin, value, tm)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return end
    local l = list(plugin)
    for _i, v in ipairs(l) do
        if v:lower() == value:lower() then return end
    end
    l[#l + 1] = value
    changed(plugin, tm)
end

function M.getSettingsItem(plugin)
    return {
        text_func = function()
            local n = #list(plugin)
            if n == 0 then return _("Folders to skip when looking for books: none") end
            return T(_("Folders to skip when looking for books: %1"), n)
        end,
        help_text = _("Big folders you keep comics, manga or PDFs in can make looking for your books slow. Folders listed here (and everything inside them) are left out when the plugin looks for books on the device. A name without a “/” is skipped wherever it is."),
        sub_item_table_func = function() return M.items(plugin) end,
    }
end

function M.items(plugin)
    local items = {
        {
            text = _("Choose a folder to skip…"),
            scan_skip_menu = true,
            keep_menu_open = true,
            callback = function(tm)
                require("folderpicker").choose(plugin:getDownloadDir(), function(path)
                    add(plugin, path, tm)
                end)
            end,
        },
        {
            text = _("Skip folders with a name…"),
            keep_menu_open = true,
            callback = function(tm)
                local dialog
                dialog = InputDialog:new{
                    title = _("Skip folders named"),
                    input_hint = _("e.g. Comics"),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        { text = _("Skip"), is_enter_default = true, callback = function()
                            local text = dialog:getInputText()
                            UIManager:close(dialog)
                            for part in text:gmatch("[^,]+") do add(plugin, part, tm) end
                        end },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
            separator = true,
        },
    }
    for _i, v in ipairs(list(plugin)) do
        items[#items + 1] = {
            text = T(_("✗ %1"), v),
            help_text = _("Tap to look in this folder again."),
            keep_menu_open = true,
            callback = function(tm)
                local l = list(plugin)
                for k = #l, 1, -1 do
                    if l[k] == v then table.remove(l, k) end
                end
                changed(plugin, tm)
            end,
        }
    end
    if #list(plugin) == 0 then
        items[#items + 1] = { text = _("No folders are skipped."), enabled_func = function() return false end }
    end
    return items
end

return M
