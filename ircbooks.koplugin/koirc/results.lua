--[[--
Parsing of the results file that IRC search bots (SearchBot, SearchOok, ...)
send back after an @search request. Every downloadable entry is a line of the
form

    !BotName Author - Title.epub  ::INFO:: 1.2MB

and requesting the book means sending everything before "::INFO::" to the
channel.
]]

local M = {}

local function isValidUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else return false end
        for k = 1, len - 1 do
            local cc = s:byte(i + k)
            if not cc or cc < 0x80 or cc > 0xBF then return false end
        end
        i = i + len
    end
    return true
end

--- Return text as valid UTF-8, treating it as Latin-1 if it is not.
function M.toUtf8(s)
    s = s:gsub("^\239\187\191", "") -- BOM
    if isValidUtf8(s) then return s end
    return (s:gsub("[\128-\255]", function(ch)
        local b = ch:byte()
        return string.char(0xC0 + math.floor(b / 64), 0x80 + b % 64)
    end))
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse a results text into an array of entries:
-- {bot=, title=, request=, size=, ext=}
function M.parse(text)
    text = M.toUtf8(text)
    local list, seen = {}, {}
    for line in text:gmatch("[^\r\n]+") do
        line = trim(line)
        if line:sub(1, 1) == "!" then
            local request = line:gsub("%s*::INFO::.*$", ""):gsub("%s*::HASH::.*$", "")
            request = trim(request)
            local bot, title = request:match("^!(%S+)%s+(.+)$")
            if bot and not seen[request] then
                seen[request] = true
                local size = line:match("::INFO::%s*([%d%.,]+%s*[KMGkmg]?[Bb]?)")
                local ext = title:match("%.(%w+)$")
                list[#list + 1] = {
                    bot = bot,
                    title = title,
                    request = request,
                    size = size and trim(size) or nil,
                    ext = ext and ext:lower() or nil,
                }
            end
        end
    end
    return list
end

--- Keep only entries whose extension is in the comma separated list
-- (e.g. "epub, mobi"). An empty filter keeps everything.
function M.filter(list, formats)
    if not formats or trim(formats) == "" then return list end
    local allowed = {}
    for f in formats:lower():gmatch("[%w]+") do allowed[f] = true end
    local out = {}
    for _, e in ipairs(list) do
        if e.ext and allowed[e.ext] then out[#out + 1] = e end
    end
    return out
end

--- Keep only entries whose title (or bot name) contains every word of text,
-- ignoring case. An empty text keeps everything.
function M.search(list, text)
    local words = {}
    for w in (text or ""):lower():gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return list end
    local out = {}
    for _, e in ipairs(list) do
        local hay = (e.title .. " " .. e.bot):lower()
        local ok = true
        for i = 1, #words do
            if not hay:find(words[i], 1, true) then ok = false break end
        end
        if ok then out[#out + 1] = e end
    end
    return out
end

--- Count entries per extension. Returns an array of {ext=, count=}, most
-- common first.
function M.formats(list)
    local counts = {}
    for _, e in ipairs(list) do
        local ext = e.ext or "?"
        counts[ext] = (counts[ext] or 0) + 1
    end
    local out = {}
    for ext, n in pairs(counts) do out[#out + 1] = { ext = ext, count = n } end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.ext < b.ext
    end)
    return out
end

return M
