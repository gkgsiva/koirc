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

return M
