--[[--
Screen preferences shared by the plugin's lists: how many lines per page
(compact for more books per page, large for bigger tap targets), and gentler
e-ink refreshes for messages that come and go.
]]

local M = {}

M.SIZES = { "compact", "normal", "large" }

local LAYOUT = {
    -- items_per_page, items_max_lines
    compact = { 14, 2 },
    normal = { 8, 4 },
    large = { 6, 3 },
}

--- Fields to merge into a Menu:new{} table for the chosen list size.
function M.menuOpts(settings)
    local l = LAYOUT[(settings or {}).list_size or "normal"] or LAYOUT.normal
    return {
        items_per_page = l[1],
        items_max_lines = l[2],
        multilines_show_more_text = true,
        multilines_forced = true,
    }
end

--- Copy the list-size fields into a Menu:new{} table.
function M.apply(settings, t)
    for k, v in pairs(M.menuOpts(settings)) do t[k] = v end
    return t
end

--- Make a full-screen list really cover the whole screen.
-- On some setups (ZenOS, night mode) the list came out shorter than the
-- screen, so the file browser's own page bar (e.g. "1 / 2" with arrows that
-- do nothing) showed below the list's, and old text ghosted through. This
-- paints the whole screen first, makes the list own every tap on it, and
-- asks for a full (flashing) refresh when it opens. Returns menu.
function M.cover(menu)
    local ok, Screen = pcall(function() return require("device").screen end)
    if not ok or not Screen then return menu end
    local w, h = Screen:getWidth(), Screen:getHeight()
    local paintTo = menu.paintTo
    menu.paintTo = function(self, bb, x, y)
        local bok, Blitbuffer = pcall(require, "ffi/blitbuffer")
        if bok and bb.paintRect then
            pcall(bb.paintRect, bb, 0, 0, w, h, Blitbuffer.COLOR_WHITE)
        end
        return paintTo(self, bb, x, y)
    end
    menu.covers_fullscreen = true
    local onShow = menu.onShow
    menu.onShow = function(self, ...)
        local UIManager = require("ui/uimanager")
        UIManager:setDirty(nil, "full")
        if onShow then return onShow(self, ...) end
    end
    return menu
end

return M
