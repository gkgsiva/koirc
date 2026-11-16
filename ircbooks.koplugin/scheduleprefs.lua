--[[--
Download schedule settings: background downloads only in set hours, only
while Wi-Fi is already on, only while charging (koirc/schedule.lua), and the
checks the queue uses.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("gettext")
local T = require("ffi/util").template

local Schedule = require("koirc/schedule")

local M = {}

--- Is Wi-Fi on and connected? nil when it can't be told.
function M.onWifi()
    local ok, res = pcall(function()
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr.isWifiOn and NetworkMgr:isWifiOn() == false then return false end
        if NetworkMgr.isConnected then return NetworkMgr:isConnected() and true or false end
        if NetworkMgr.isOnline then return NetworkMgr:isOnline() and true or false end
        return nil
    end)
    if ok then return res end
    return nil
end

function M.charging()
    local ok, res = pcall(function() return require("hardcoverui").isCharging() end)
    if ok then return res end
    return nil
end

local REASONS = {
    wifi = _("until Wi-Fi is on"),
    charging = _("until the charger is connected"),
}

--- For the queue: true, or false and a short reason for messages.
function M.mayRun(settings)
    local ok, why, wait = Schedule.allowed(settings, { now = os.time(), wifi = M.onWifi, charging = M.charging })
    if ok then return true end
    if why == "hours" then
        local h = settings.queue_hours
        return false, T(_("until %1"), string.format("%02d:00", tonumber(h.from) or 0)), wait
    end
    return false, REASONS[why] or why
end

--- Before a run started by hand: when the schedule says wait, ask whether
-- to start now anyway. go(opts) with opts.now = true to ignore it.
function M.askStart(plugin, go)
    local ok, why = M.mayRun(plugin.settings)
    if ok then return go({}) end
    local UIManager = require("ui/uimanager")
    UIManager:show(ConfirmBox:new{
        text = T(_("Your download schedule says background downloads wait %1.\n\nStart these now anyway, or wait?"), why),
        ok_text = _("Start now"),
        cancel_text = _("Wait"),
        ok_callback = function() go({ now = true }) end,
        cancel_callback = function() go({}) end,
    })
end

function M.getSettingsItem(plugin)
    local s = function() return plugin.settings end
    local function save(tm)
        plugin:saveSettings()
        if tm then tm:updateItems() end
    end
    return {
        text_func = function()
            local d = Schedule.describe(s())
            return d and T(_("Download schedule: %1"), d) or _("Download schedule: any time")
        end,
        sub_item_table_func = function()
            local items = {
                {
                    text = _("Any time"),
                    radio = true,
                    checked_func = function()
                        local h = s().queue_hours
                        return type(h) ~= "table" or h.from == h.to
                    end,
                    keep_menu_open = true,
                    callback = function(tm)
                        s().queue_hours = nil
                        save(tm)
                    end,
                },
            }
            for _i, c in ipairs(Schedule.HOUR_CHOICES) do
                items[#items + 1] = {
                    text = T(_("Only %1"), Schedule.hoursText(c.from, c.to)),
                    radio = true,
                    checked_func = function()
                        local h = s().queue_hours
                        return type(h) == "table" and h.from == c.from and h.to == c.to
                    end,
                    keep_menu_open = true,
                    callback = function(tm)
                        s().queue_hours = { from = c.from, to = c.to }
                        save(tm)
                    end,
                }
            end
            items[#items].separator = true
            items[#items + 1] = {
                text = _("Only while Wi-Fi is already on"),
                help_text = _("Background downloads wait until Wi-Fi is on, instead of turning it on for them."),
                checked_func = function() return s().queue_wifi_only == true end,
                keep_menu_open = true,
                callback = function(tm)
                    s().queue_wifi_only = not s().queue_wifi_only or nil
                    save(tm)
                end,
            }
            items[#items + 1] = {
                text = _("Only while charging"),
                checked_func = function() return s().queue_charging_only == true end,
                keep_menu_open = true,
                callback = function(tm)
                    s().queue_charging_only = not s().queue_charging_only or nil
                    save(tm)
                end,
            }
            items[#items].help_text = _("Lists and series you start yourself ask whether to start now anyway. Want to read and followed-author downloads always wait.")
            return items
        end,
    }
end

return M
