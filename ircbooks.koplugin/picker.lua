--[[--
Which file to download: the scoring options (koirc/pick.lua) for the
plugin, the "why this file" dialog with other copies to pick instead, the
question asked before a background download when set, bots to avoid, and
the "Choosing files" settings.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Pick = require("koirc/pick")
local results = require("koirc/results")
local LearnStore = require("learnstore")

local M = {}

-- Background picks: download the best one ("auto"), ask when it looks
-- doubtful ("unsure"), or always ask ("always").
M.ASK_MODES = { "auto", "unsure", "always" }
local ASK_NAMES = {
    auto = _("pick the best file myself"),
    unsure = _("ask me when unsure"),
    always = _("always ask me"),
}

--- Bots never to download from: a set of lowercase names.
function M.blocked(settings)
    local set = {}
    for _i, b in ipairs(type(settings.blocked_bots) == "table" and settings.blocked_bots or {}) do
        set[tostring(b):lower()] = true
    end
    return set
end

function M.isBlocked(settings, bot)
    return M.blocked(settings)[tostring(bot or ""):lower()] == true
end

function M.setBlocked(plugin, bot, on)
    local s = plugin.settings
    local list = type(s.blocked_bots) == "table" and s.blocked_bots or {}
    local out = {}
    for _i, b in ipairs(list) do
        if tostring(b):lower() ~= tostring(bot):lower() then out[#out + 1] = b end
    end
    if on then out[#out + 1] = bot end
    s.blocked_bots = out
    plugin:saveSettings()
    if plugin.view then plugin.view.shown_memo = nil end
end

--- Options for Pick.rank. extra: book, query, tried, owned, drop_offline.
function M.options(plugin, extra)
    local s = plugin.settings
    local opts = {
        prefs = results.parseFormats(s.preferred_formats),
        health = LearnStore.health(),
        learn = s.learn_picks ~= false,
        tracker = plugin.retry,
        online = function(bot) return plugin.fetcher:botOnline(bot) end,
        blocked = M.blocked(s),
    }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return opts
end

--- Results ranked for a book (or a search), with the reasons.
function M.rank(plugin, list, extra)
    return Pick.rank(list, M.options(plugin, extra))
end

--- Should the background queue ask before this pick?
function M.askFor(plugin, inf)
    local mode = plugin.settings.queue_pick or "auto"
    if mode == "always" then return true end
    if mode == "unsure" then return Pick.unsure(inf) end
    return false
end

local function line(e, inf)
    local parts = { results.badge(e), e.bot }
    if inf and #(inf.warn or {}) > 0 then parts[#parts + 1] = "⚠" end
    return table.concat(parts, " · ")
end

--- "Why this file?": the reasons for the best pick, and the next best
-- copies to pick instead. choose(entry) downloads one.
function M.showWhy(best, ranked, info, choose, title)
    local dialog
    local buttons = {}
    local shown = 0
    for _i, e in ipairs(ranked or {}) do
        if shown >= 5 then break end
        shown = shown + 1
        local inf = info and info[e]
        buttons[#buttons + 1] = {{
            text = (e == best and "★ " or "") .. line(e, inf),
            callback = function()
                UIManager:close(dialog)
                choose(e)
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = function() UIManager:close(dialog) end }}
    local inf = info and info[best]
    local text = T(_("%1\n\nWhy this file:\n%2\n\nTap a file below to download it instead."),
        title or best.title, Pick.explain(inf) ~= "" and Pick.explain(inf) or _("the best match found"))
    dialog = ButtonDialog:new{ title = text, title_align = "left", buttons = buttons }
    UIManager:show(dialog)
end

--- The background queue asks which file to get for a book. done(entry)
-- or done(nil) to skip the book.
function M.askBackground(plugin, item, candidates, info, done)
    local dialog
    local answered = false
    local function answer(e)
        if answered then return end
        answered = true
        UIManager:close(dialog)
        done(e)
    end
    local buttons = {}
    for i = 1, math.min(#candidates, 6) do
        local e = candidates[i]
        buttons[#buttons + 1] = {{
            text = (i == 1 and "★ " or "") .. line(e, info and info[e]),
            callback = function() answer(e) end,
        }}
    end
    buttons[#buttons + 1] = {
        { text = _("Skip this book"), callback = function() answer(nil) end },
        { text = _("Download ★"), callback = function() answer(candidates[1]) end },
    }
    local best = candidates[1]
    local text = T(_("Background download: which file for\n“%1”?\n\n★ %2\n%3"),
        item.book.title, best.title, Pick.explain(info and info[best]))
    dialog = ButtonDialog:new{
        title = text,
        title_align = "left",
        buttons = buttons,
        -- Closing it without a choice skips the book, so the queue goes on.
        tap_close_callback = function() answer(nil) end,
    }
    UIManager:show(dialog)
end

--- Settings → Choosing files.
function M.getSettingsItem(plugin)
    local s = function() return plugin.settings end
    local function save(tm)
        plugin:saveSettings()
        if plugin.view then plugin.view.shown_memo = nil end
        if tm then tm:updateItems() end
    end
    return {
        text = _("Choosing files…"),
        sub_item_table_func = function()
            local items = {}
            for _i, mode in ipairs(M.ASK_MODES) do
                items[#items + 1] = {
                    text = T(_("Background downloads: %1"), ASK_NAMES[mode]),
                    help_text = _("Lists, series and Want to read downloads pick the best file by title and author, format, size, abridged or sample copies and bot health. “Ask me when unsure” shows the files when the best one has a warning or the title only partly matches."),
                    radio = true,
                    checked_func = function() return (s().queue_pick or "auto") == mode end,
                    keep_menu_open = true,
                    callback = function(tm)
                        s().queue_pick = mode
                        save(tm)
                    end,
                }
            end
            items[#items].separator = true
            items[#items + 1] = {
                text = _("Check downloaded files and retry if damaged"),
                help_text = _("Empty files, error pages, cut-off EPUBs and PDFs, and files that are not books are deleted and the next bot is tried. Books with the wrong extension (a MOBI called .epub) are renamed so KOReader opens them."),
                checked_func = function() return s().quality_check ~= false end,
                keep_menu_open = true,
                callback = function(tm)
                    s().quality_check = s().quality_check == false
                    save(tm)
                end,
            }
            items[#items + 1] = {
                text = _("Offer a copy in a better format"),
                help_text = _("After a download in a format that is not your first choice (or reads badly on an e-reader), offer the same book in a better format when the search found one. Background downloads already prefer your formats."),
                checked_func = function() return s().offer_better_format ~= false end,
                keep_menu_open = true,
                callback = function(tm)
                    s().offer_better_format = s().offer_better_format == false
                    save(tm)
                end,
            }
            items[#items + 1] = {
                text_func = function()
                    local n = #(type(s().blocked_bots) == "table" and s().blocked_bots or {})
                    return T(_("Avoided bots: %1"), n)
                end,
                keep_menu_open = true,
                callback = function(tm) M.showBlocked(plugin, tm) end,
            }
            return items
        end,
    }
end

function M.showBlocked(plugin, tm)
    local list = type(plugin.settings.blocked_bots) == "table" and plugin.settings.blocked_bots or {}
    if #list == 0 then
        UIManager:show(InfoMessage:new{ text = _("No avoided bots. Hold a result and choose “Avoid this bot” to never download from a bot.") })
        return
    end
    local dialog
    local buttons = {}
    for _i, b in ipairs(list) do
        buttons[#buttons + 1] = {{
            text = T(_("Allow %1 again"), b),
            callback = function()
                UIManager:close(dialog)
                M.setBlocked(plugin, b, false)
                if tm then tm:updateItems() end
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{ title = _("Avoided bots"), buttons = buttons }
    UIManager:show(dialog)
end

return M
