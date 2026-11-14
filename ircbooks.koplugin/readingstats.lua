--[[--
A small reading dashboard: pages and time per day over the last week or
month, a reading streak, and the books read most. The numbers come from
KOReader's own Reading statistics plugin database; nothing is sent anywhere.
]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("koirc/debuglog").wrap(require("logger"))
local _ = require("gettext")
local T = require("ffi/util").template

local Stats = require("koirc/stats")

local ReadingStats = {}

local function dbPath()
    local dir = DataStorage.getSettingsDir and DataStorage:getSettingsDir() or (DataStorage:getDataDir() .. "/settings")
    return dir .. "/statistics.sqlite3"
end

local function midnight(t)
    local d = os.date("*t", t)
    d.hour, d.min, d.sec = 0, 0, 0
    return os.time(d)
end

--- Rows of {day, title, pages, seconds} since the start of the first day.
function ReadingStats.load(days)
    local path = dbPath()
    if lfs.attributes(path, "mode") ~= "file" then
        return nil, _("No reading statistics yet. Turn on the Reading statistics plugin (Tools → Reading statistics) and read for a while.")
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return nil, _("This KOReader version cannot read the statistics database.") end
    local since = midnight(os.time()) - (days - 1) * 86400
    local rows = {}
    local okq, err = pcall(function()
        local conn = SQ3.open(path)
        local res = conn:exec(string.format([[
            SELECT strftime('%%Y-%%m-%%d', p.start_time, 'unixepoch', 'localtime') AS day,
                   b.title, count(DISTINCT p.page), sum(p.duration)
            FROM page_stat_data p LEFT JOIN book b ON b.id = p.id_book
            WHERE p.start_time >= %d
            GROUP BY day, p.id_book]], since))
        conn:close()
        if res and res[1] then
            for i = 1, #res[1] do
                rows[#rows + 1] = {
                    day = tostring(res[1][i]),
                    title = res[2][i] and tostring(res[2][i]) or nil,
                    pages = tonumber(res[3][i]) or 0,
                    seconds = tonumber(res[4][i]) or 0,
                }
            end
        end
    end)
    if not okq then
        logger.warn("ircbooks: reading statistics query failed:", err)
        return nil, T(_("Could not read the statistics database:\n%1"), tostring(err))
    end
    return rows
end

local LABELS = {
    today = _("Today"),
    pages = _("pages"),
    average = _("Per reading day"),
    streak = _("Days in a row"),
    books = _("Books"),
}

--- Show the dashboard. ui: the plugin's ui, used to save the pages read in
-- an open book first (the statistics plugin writes them only now and then).
function ReadingStats.show(ui, days)
    days = days or 7
    if ui and ui.statistics and ui.statistics.insertDB then
        pcall(ui.statistics.insertDB, ui.statistics)
    end
    local rows, err = ReadingStats.load(days)
    if not rows then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local now = os.time()
    local labels = {}
    for k, v in pairs(LABELS) do labels[k] = v end
    labels.period = T(_("Last %1 days"), days)
    local text = Stats.format(Stats.summarize(rows), Stats.days(now, days), now, labels)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = T(_("Reading stats · last %1 days"), days),
        text = text,
        buttons_table = {{
            { text = _("7 days"), enabled = days ~= 7, callback = function()
                UIManager:close(viewer)
                ReadingStats.show(ui, 7)
            end },
            { text = _("30 days"), enabled = days ~= 30, callback = function()
                UIManager:close(viewer)
                ReadingStats.show(ui, 30)
            end },
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
        }},
    }
    UIManager:show(viewer)
end

return ReadingStats
