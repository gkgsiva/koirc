-- Tiny reader for the OPDS/Atom feeds the Library server produces.
local M = {}

function M.unescape(s)
    s = s:gsub("&#x(%x+);", function(h) return utf8 and utf8.char and utf8.char(tonumber(h, 16)) or "?" end)
    s = s:gsub("&#(%d+);", function(d) return utf8 and utf8.char and utf8.char(tonumber(d)) or "?" end)
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return s
end

local function attrs(s)
    local t = {}
    for k, v in s:gmatch('([%w:_%-]+)%s*=%s*"([^"]*)"') do t[k] = M.unescape(v) end
    for k, v in s:gmatch("([%w:_%-]+)%s*=%s*'([^']*)'") do if t[k] == nil then t[k] = M.unescape(v) end end
    return t
end

local function links(s)
    local out = {}
    for a in s:gmatch("<link%s+([^>]-)/?>") do out[#out + 1] = attrs(a) end
    return out
end

--- Parse a feed into { title=, links={ {rel=,href=,type=,...} }, entries={ {title=,id=,links=} } }.
function M.parse(xml)
    local feed = { entries = {}, links = {} }
    local rest = xml:gsub("<entry>(.-)</entry>", function(body)
        feed.entries[#feed.entries + 1] = {
            title = M.unescape((body:match("<title[^>]*>(.-)</title>") or ""):gsub("^%s+", ""):gsub("%s+$", "")),
            id = M.unescape(body:match("<id>(.-)</id>") or ""),
            links = links(body),
            categories = (function()
                local c = {}
                for a in body:gmatch("<category%s+([^>]-)/?>") do c[#c + 1] = attrs(a) end
                return c
            end)(),
            calibre_series = M.unescape(body:match("<calibre:series>(.-)</calibre:series>") or ""),
            calibre_index = body:match("<calibre:series_index>(.-)</calibre:series_index>"),
        }
        return ""
    end)
    feed.title = M.unescape(rest:match("<title[^>]*>(.-)</title>") or "")
    feed.links = links(rest)
    return feed
end

--- Series of a book entry: name, number (string or nil). Reads the Library server's
-- <calibre:series>/<calibre:series_index> first, then the <category label="Series: Name #3"/> fallback.
function M.series(entry)
    if entry.calibre_series and entry.calibre_series ~= "" then
        local idx = entry.calibre_index and entry.calibre_index:match("^%s*([%d%.]+)%s*$")
        return entry.calibre_series, idx
    end
    for _, c in ipairs(entry.categories or {}) do
        local rest = (c.label or ""):match("^Series:%s*(.+)$")
        if rest then
            local name, n = rest:match("^(.-)%s+#([%d%.]+)$")
            if name then return name, n end
            return rest, nil
        end
    end
end

function M.link(entry, rel)
    for _, l in ipairs(entry.links) do if l.rel == rel then return l end end
end

return M
