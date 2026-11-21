-- Tiny reader for the OPDS/Atom feeds the Library server produces.
local M = {}

--- Code point -> UTF-8 (LuaJIT, which KOReader uses, has no utf8 library).
local function utf8char(n)
    n = tonumber(n)
    if not n or n < 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) then return "?" end
    local f = math.floor
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0 + f(n / 64), 0x80 + n % 64) end
    if n < 0x10000 then return string.char(0xE0 + f(n / 4096), 0x80 + f(n / 64) % 64, 0x80 + n % 64) end
    return string.char(0xF0 + f(n / 262144), 0x80 + f(n / 4096) % 64, 0x80 + f(n / 64) % 64, 0x80 + n % 64)
end
M.utf8char = utf8char

local function numeric(s)
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", utf8char)
    return s
end

function M.unescape(s)
    s = numeric(s)
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    -- Titles that were already HTML-escaped before they reached the server (e.g. "Don&#39;t"
    -- from an import) arrive as "&amp;#39;": decode those numeric references too.
    s = numeric(s)
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
    local rest = xml:gsub("<entry[^>]*>(.-)</entry>", function(body)
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

--- Library folder names a book entry belongs to: the server lists each folder as a
-- <category term="Name" label="Name"/>; the series category is the "Series: ..." one.
function M.folders(entry)
    local out = {}
    for _, c in ipairs(entry.categories or {}) do
        local name = c.label or c.term
        if name and name ~= "" and not name:match("^Series:") then out[#out + 1] = name end
    end
    return out
end

function M.link(entry, rel)
    for _, l in ipairs(entry.links) do if l.rel == rel then return l end end
end

return M
