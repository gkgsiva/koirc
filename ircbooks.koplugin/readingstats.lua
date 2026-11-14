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

local function parseDate(d)
    local y, m, dd = tostring(d or ""):match("^(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 0 }
end

--- The goal to show: the Hardcover reading goal for books (from the last
-- sync) when there is one for now, else the yearly goal set here.
-- Returns {title, count, goal, from, to, source} or nil.
function ReadingStats.currentGoal(plugin)
    if not plugin then return nil end
    local s = plugin.settings
    local now = os.time()
    if s.reading_goal_hardcover ~= false and plugin.hardcover then
        local saved = plugin.hardcover:storeValue("goals")
        for _i, g in ipairs(type(saved) == "table" and saved.goals or {}) do
            local from, to = parseDate(g.start_date), parseDate(g.end_date)
            if (g.metric == "book" or g.metric == "books") and from and to and from <= now and now < to + 86400 then
                return { title = g.description or _("Hardcover goal"), count = g.progress or 0, goal = g.goal,
                         from = from, to = to + 86400, source = "hardcover" }
            end
        end
    end
    local goal = tonumber(s.reading_goal)
    if goal and goal > 0 then
        local LearnStore = require("learnstore")
        local count = LearnStore.finishedIn(os.date("%Y"))
        return { title = T(_("%1 goal"), os.date("%Y")), count = count, goal = goal, source = "local" }
    end
    return nil
end

local GOAL_LABELS = {
    goal = _("%1: %2 of %3 books (%4%)"),
    ahead = _("%1 books ahead of schedule"),
    behind = _("%1 books behind schedule"),
    on_track = _("Right on schedule"),
    done = _("Goal reached. Well done!"),
    days_left = _("%1 days left for %2 more books"),
}

function ReadingStats.goalText(plugin)
    local g = ReadingStats.currentGoal(plugin)
    if not g then return nil end
    local p = Stats.goal(g.count, g.goal, os.time(), g.from, g.to)
    return table.concat(Stats.goalLines(p, g.title, T, GOAL_LABELS), "\n")
end

--- Ask for the number of books to read this year.
function ReadingStats.setGoal(plugin, on_done)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = T(_("Books to read in %1"), os.date("%Y")),
        input = tostring(plugin.settings.reading_goal or ""),
        input_hint = "24",
        input_type = "number",
        description = _("Finished books are counted when you reach the end of a book. A reading goal set on Hardcover is shown instead, after a sync."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Remove goal"), callback = function()
                UIManager:close(dialog)
                plugin.settings.reading_goal = nil
                plugin:saveSettings()
                if on_done then on_done() end
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local n = tonumber(dialog:getInputText())
                UIManager:close(dialog)
                if n and n > 0 then
                    plugin.settings.reading_goal = math.floor(n)
                    plugin:saveSettings()
                end
                if on_done then on_done() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Show the dashboard. ui: the plugin's ui, used to save the pages read in
-- an open book first (the statistics plugin writes them only now and then).
-- plugin: for the reading goal.
function ReadingStats.show(ui, days, plugin)
    days = days or 7
    if ui and ui.statistics and ui.statistics.insertDB then
        pcall(ui.statistics.insertDB, ui.statistics)
    end
    local rows, err = ReadingStats.load(days)
    local goal_text = ReadingStats.goalText(plugin)
    if not rows and not goal_text then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local now = os.time()
    local labels = {}
    for k, v in pairs(LABELS) do labels[k] = v end
    labels.period = T(_("Last %1 days"), days)
    local text = rows and Stats.format(Stats.summarize(rows), Stats.days(now, days), now, labels) or err
    if goal_text then text = goal_text .. "\n\n" .. text end
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = T(_("Reading stats · last %1 days"), days),
        text = text,
        buttons_table = {{
            { text = _("7 days"), enabled = days ~= 7, callback = function()
                UIManager:close(viewer)
                ReadingStats.show(ui, 7, plugin)
            end },
            { text = _("30 days"), enabled = days ~= 30, callback = function()
                UIManager:close(viewer)
                ReadingStats.show(ui, 30, plugin)
            end },
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
        }, plugin and {
            { text = _("Set yearly goal…"), callback = function()
                UIManager:close(viewer)
                ReadingStats.setGoal(plugin, function() ReadingStats.show(ui, days, plugin) end)
            end },
        } or nil},
    }
    UIManager:show(viewer)
end

return ReadingStats
