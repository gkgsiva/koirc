--[[--
Download a list of searches: type several searches (one per line, e.g.
"sanderson mistborn" or "Andy Weir - The Martian"); each is searched on IRC
in the background, its best result (koirc/pick.lua, scored on the words
searched for) is downloaded, and every book can go into a KOReader
collection picked before the run starts.
]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

-- Searches per run at most.
M.MAX = 50
-- A result needs at least this share of the searched words (x10) to be
-- downloaded without asking: most words, so "mistborn" alone doesn't pick
-- any Sanderson book.
M.MIN_MATCH = 6

--- Lines of text to queue items: {title, query, is_query}. Blank lines,
-- doubles and "# notes" are left out.
function M.parse(text)
    local out, seen = {}, {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        line = line:gsub("^%s*[%-%*•]%s+", ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        local key = line:lower()
        if line ~= "" and not line:match("^#") and not seen[key] then
            seen[key] = true
            out[#out + 1] = { title = line, query = line, is_query = true }
            if #out >= M.MAX then break end
        end
    end
    return out
end

--- Only results that have most of the searched words.
function M.keep(ranked, info)
    local out = {}
    for _i, e in ipairs(ranked) do
        local inf = info and info[e]
        if not inf or (inf.match or 0) >= M.MIN_MATCH then out[#out + 1] = e end
    end
    return out
end

function M.show(plugin)
    local dialog
    dialog = InputDialog:new{
        title = _("Download a list of searches"),
        input = plugin.settings.search_list_draft or "",
        input_hint = _("One search per line, e.g.\nsanderson mistborn\nAndy Weir - The Martian"),
        description = _("Each line is searched on IRC and its best result is downloaded in the background. Next you pick the folder and, if you like, a collection to add the books to."),
        allow_newline = true,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    plugin.settings.search_list_draft = dialog:getInputText()
                    plugin:saveSettings()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Clear"),
                callback = function()
                    plugin.settings.search_list_draft = nil
                    plugin:saveSettings()
                    dialog:setInputText("")
                end,
            },
            {
                text = _("Download"),
                callback = function()
                    local text = dialog:getInputText()
                    local books = M.parse(text)
                    if #books == 0 then
                        UIManager:show(InfoMessage:new{ text = _("Type at least one search."), timeout = 2 })
                        return
                    end
                    plugin.settings.search_list_draft = text
                    plugin:saveSettings()
                    UIManager:close(dialog)
                    if plugin.queue:isRunning() then
                        plugin:showQueueBusy()
                        return
                    end
                    plugin:startQueue(books, T(_("%1 searches"), #books), function()
                        -- Done with this list: start empty next time.
                        plugin.settings.search_list_draft = nil
                        plugin:saveSettings()
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return M
