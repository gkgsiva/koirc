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
    -- For cover(): page turn preferences.
    t._ircb_settings = settings
    return t
end

--- Make a full-screen list really cover the whole screen, and keep page
-- turns quick on e-ink.
-- On some setups (ZenOS, night mode) the list came out shorter than the
-- screen, so the file browser's own page bar (e.g. "1 / 2" with arrows that
-- do nothing) showed below the list's, and old text ghosted through. This
-- paints whatever part of the screen the list does not cover, makes the list
-- own every tap on it, and asks for a full (flashing) refresh when it opens.
--
-- Page turns: KOReader only builds the rows of the page shown, but redraws
-- the whole screen with its normal "ui" refresh each time, which is slow on
-- e-ink. Turns use a fast refresh instead, with a cleaner one every few
-- turns to clear ghosting (Settings → List size → Fast page turns). A swipe
-- on a one-page list no longer rebuilds and redraws the same page.
-- settings: the plugin settings (optional). Returns menu.
function M.cover(menu, settings)
    local ok, Screen = pcall(function() return require("device").screen end)
    if not ok or not Screen then return menu end
    local Pager = require("koirc/pager")
    local w, h = Screen:getWidth(), Screen:getHeight()
    local bok, Blitbuffer = pcall(require, "ffi/blitbuffer")
    local paintTo = menu.paintTo
    menu.paintTo = function(self, bb, x, y)
        -- The list paints its own background; only fill what it leaves out.
        if bok and bb.paintRect then
            local d = self.dimen
            local rect = d and { x = x or 0, y = y or 0, w = d.w, h = d.h }
            -- Wipe the whole screen once when the list opens.
            if self._ircb_wipe then rect, self._ircb_wipe = nil, nil end
            for _i, r in ipairs(Pager.uncovered(w, h, rect)) do
                pcall(bb.paintRect, bb, r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE)
            end
        end
        return paintTo(self, bb, x, y)
    end
    menu.covers_fullscreen = true
    local onShow = menu.onShow
    menu.onShow = function(self, ...)
        local UIManager = require("ui/uimanager")
        self._ircb_wipe = true
        UIManager:setDirty(nil, "full")
        if onShow then return onShow(self, ...) end
    end
    local turns = 0
    local onGotoPage = menu.onGotoPage
    if onGotoPage then
        menu.onGotoPage = function(self, page)
            if Pager.isNoop(self.page, page, self.page_num) then return true end
            turns = turns + 1
            local s = settings or self._ircb_settings or {}
            local mode = Pager.turnMode(turns, s.fast_page_turns, s.page_turn_cleanup)
            if mode == "ui" then return onGotoPage(self, page) end
            -- Swap the refresh KOReader asks for while it redraws the page.
            local UIManager = require("ui/uimanager")
            local real = UIManager.setDirty
            UIManager.setDirty = function(um, widget, refresh, ...)
                if widget == self.show_parent or widget == self then
                    if type(refresh) == "function" then
                        local f = refresh
                        refresh = function()
                            local _m, region, dither = f()
                            return mode, region, dither
                        end
                    elseif type(refresh) == "string" then
                        refresh = mode
                    end
                end
                return real(um, widget, refresh, ...)
            end
            local rok, res = pcall(onGotoPage, self, page)
            UIManager.setDirty = real
            if not rok then error(res) end
            return res
        end
    end
    return menu
end

--- True when widget is the window on top (nothing shown over it).
function M.isOnTop(widget)
    local ok, top = pcall(function()
        local UIManager = require("ui/uimanager")
        local stack = UIManager._window_stack
        return stack and stack[#stack] and stack[#stack].widget
    end)
    return ok and top == widget
end

return M
