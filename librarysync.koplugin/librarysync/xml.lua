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
        }
        return ""
    end)
    feed.title = M.unescape(rest:match("<title[^>]*>(.-)</title>") or "")
    feed.links = links(rest)
    return feed
end

function M.link(entry, rel)
    for _, l in ipairs(entry.links) do if l.rel == rel then return l end end
end

return M
