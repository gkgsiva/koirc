--[[--
Trimmed menu: hide the plugin's menu entries you don't use, so the menu
stays short on e-ink. "Search for a book…" and "Settings" always stay, so
nothing can be locked out.
]]

local _ = require("gettext")

local M = {}

-- Entries that can't be hidden.
M.ALWAYS = { search = true, settings = true }

--- The items whose id is not hidden.
function M.visible(items, hidden)
    hidden = type(hidden) == "table" and hidden or {}
    local out = {}
    for _i, item in ipairs(items) do
        if M.ALWAYS[item.id] or not hidden[item.id] then
            local copy = {}
            for k, v in pairs(item) do copy[k] = v end
            out[#out + 1] = copy
        end
    end
    return out
end

local function label(item)
    if item.text then return item.text end
    local ok, t = pcall(item.text_func)
    return ok and t or tostring(item.id)
end

--- Settings → Menu items: one checkbox per entry (checked = shown).
function M.settingsItems(plugin, items)
    local out = {}
    for _i, item in ipairs(items) do
        if not M.ALWAYS[item.id] then
            local id = item.id
            out[#out + 1] = {
                text_func = function() return label(item) end,
                checked_func = function()
                    local hidden = plugin.settings.hidden_menu
                    return not (type(hidden) == "table" and hidden[id])
                end,
                keep_menu_open = true,
                callback = function()
                    local hidden = type(plugin.settings.hidden_menu) == "table" and plugin.settings.hidden_menu or {}
                    hidden[id] = (not hidden[id]) or nil
                    plugin.settings.hidden_menu = hidden
                    plugin:saveSettings()
                end,
            }
        end
    end
    out[#out + 1] = {
        text = _("Show everything again"),
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            plugin.settings.hidden_menu = nil
            plugin:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
    out[#out + 1] = {
        text = _("Hidden entries take effect the next time the menu opens. Search and Settings always stay."),
        enabled_func = function() return false end,
    }
    return out
end

return M
