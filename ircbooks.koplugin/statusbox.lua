--[[--
The "Searching… / Downloading…" box, updated in place.

v1.10 closed the message and showed a new one for every progress step, so
the whole screen flashed every few seconds during a download. This box stays
open and only its own area is redrawn with a quick e-ink refresh ("fast").
It never gets smaller while it is open (its width is fixed and its height
only grows), so the old text is always painted over and nothing behind it
needs redrawing.

Tap anywhere (or press Back) to cancel, as before.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local StatusBox = InputContainer:extend{
    text = "",
    dismiss_callback = nil,
}

function StatusBox:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.text_width = math.floor(math.min(sw, sh) * 0.75)
    self.min_h = 0
    if Device:isTouchDevice() then
        self.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function StatusBox:build()
    if self.textbox then self.textbox:free() end
    self.textbox = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("infofont"),
        width = self.text_width,
        alignment = "center",
    }
    local h = self.textbox:getSize().h
    if h > self.min_h then self.min_h = h end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        CenterContainer:new{
            dimen = Geom:new{ w = self.text_width, h = self.min_h },
            self.textbox,
        },
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, self.frame }
end

--- New text, redrawn in place with a quick refresh of the box only.
function StatusBox:setText(text)
    if text == self.text then return end
    self.text = text
    local old = self.frame.dimen and self.frame.dimen:copy()
    self:build()
    UIManager:setDirty(self, function()
        local region = self.frame.dimen
        if old and region then region = region:combine(old) end
        return "fast", region or old
    end)
end

function StatusBox:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    return true
end

function StatusBox:onTapClose()
    UIManager:close(self)
    if self.dismiss_callback then self.dismiss_callback() end
    return true
end
StatusBox.onClose = StatusBox.onTapClose

function StatusBox:onCloseWidget()
    if self.textbox then self.textbox:free() self.textbox = nil end
end

return StatusBox
