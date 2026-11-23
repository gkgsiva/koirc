--[[--
A small window showing the running sync (books done and to go, size, current book, speed,
time left), refreshed every few seconds with a partial e-ink refresh of the window only.

M.show{ title=, get_text=function() -> text, running=function() -> bool, buttons=,
        on_close=, interval= } returns the window (nil when the KOReader widgets are missing).
]]

local M = {}

function M.show(opts)
    local ok, mods = pcall(function()
        return {
            Blitbuffer = require("ffi/blitbuffer"),
            ButtonTable = require("ui/widget/buttontable"),
            CenterContainer = require("ui/widget/container/centercontainer"),
            Device = require("device"),
            FrameContainer = require("ui/widget/container/framecontainer"),
            Font = require("ui/font"),
            Geom = require("ui/geometry"),
            GestureRange = require("ui/gesturerange"),
            InputContainer = require("ui/widget/container/inputcontainer"),
            Size = require("ui/size"),
            TextBoxWidget = require("ui/widget/textboxwidget"),
            TextWidget = require("ui/widget/textwidget"),
            UIManager = require("ui/uimanager"),
            VerticalGroup = require("ui/widget/verticalgroup"),
            VerticalSpan = require("ui/widget/verticalspan"),
        }
    end)
    if not ok then return nil end
    local UIManager, Screen = mods.UIManager, mods.Device.screen
    local interval = opts.interval or 4

    local View = mods.InputContainer:extend{ name = "librarysync_status" }

    function View:textWidget(text)
        return mods.TextBoxWidget:new{
            text = text, face = mods.Font:getFace("infofont"),
            width = self.inner_w, height = self.text_h, height_overflow_show_ellipsis = true,
        }
    end

    function View:init()
        local w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
        self.inner_w = w - 2 * mods.Size.padding.large
        -- fixed height, so the window never changes size while it updates
        self.text_h = math.floor(Screen:getHeight() * 0.35)
        self.last_text = opts.get_text()
        self.body = self:textWidget(self.last_text)
        self.vgroup = mods.VerticalGroup:new{
            align = "left",
            mods.TextWidget:new{ text = opts.title, face = mods.Font:getFace("tfont"), max_width = self.inner_w },
            mods.VerticalSpan:new{ width = mods.Size.span.vertical_large },
            self.body,
            mods.VerticalSpan:new{ width = mods.Size.span.vertical_large },
            mods.ButtonTable:new{ width = self.inner_w, buttons = opts.buttons(self), show_parent = self },
        }
        self.frame = mods.FrameContainer:new{
            background = mods.Blitbuffer.COLOR_WHITE, radius = mods.Size.radius.window,
            padding = mods.Size.padding.large, self.vgroup,
        }
        self[1] = mods.CenterContainer:new{
            dimen = mods.Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }, self.frame,
        }
        if mods.Device:isTouchDevice() then
            self.ges_events = { TapOutside = { mods.GestureRange:new{ ges = "tap",
                range = mods.Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } } }
        end
        if mods.Device:hasKeys() then
            self.key_events = { Close = { { mods.Device.input.group.Back } } }
        end
        self.tick = function() self:update() end
    end

    function View:onTapOutside(_arg, ges)
        if ges and ges.pos and self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
            self:onClose()
        end
        return true
    end

    function View:onClose()
        UIManager:close(self)
        return true
    end

    function View:onShow()
        UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
        UIManager:scheduleIn(interval, self.tick)
        return true
    end

    function View:onCloseWidget()
        self.closed = true
        UIManager:unschedule(self.tick)
        UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
        if opts.on_close then pcall(opts.on_close) end
    end

    --- Re-read the status; redraw the text box only when it changed.
    function View:update()
        if self.closed then return end
        local okt, text = pcall(opts.get_text)
        if okt and text and text ~= self.last_text then
            self.last_text = text
            local new = self:textWidget(text)
            for i, w in ipairs(self.vgroup) do
                if w == self.body then self.vgroup[i] = new end
            end
            if self.body.free then pcall(self.body.free, self.body) end
            self.body = new
            UIManager:setDirty(self, function() return "ui", self.body.dimen or self.frame.dimen end)
        end
        if opts.running() then UIManager:scheduleIn(interval, self.tick) end
    end

    local view = View:new{}
    UIManager:show(view)
    return view
end

return M
