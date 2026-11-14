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

-------------------------------------------------------------------------------
-- Sizes, preferred formats and sorting
-------------------------------------------------------------------------------

M.DEFAULT_PREFERRED = "epub, azw3, mobi, pdf"

-- Archives KOReader cannot open by itself.
M.ARCHIVES = { rar = true, ["7z"] = true }

--- A counter for result lines ("!bot ...") in a results file arriving in
-- chunks. Returns fn(chunk) -> count so far. Zipped results can't be
-- counted until they are unpacked, so they stay at 0.
function M.newCounter()
    local count, last, zipped, first = 0, "\n", false, true
    return function(chunk)
        if first then
            first = false
            if chunk:sub(1, 2) == "PK" then zipped = true end
        end
        if zipped or chunk == "" then return count end
        local text = last .. chunk
        for _ in text:gmatch("\n%s*!") do count = count + 1 end
        last = chunk:sub(-1)
        return count
    end
end

--- Author, series (and number) and title guessed from a result such as
-- "Brandon Sanderson - Mistborn 01 - The Final Empire (retail).epub".
function M.parts(entry)
    local name = (entry.title or ""):gsub("%.[Zz][Ii][Pp]$", ""):gsub("%.[%w]+$", "")
    name = name:gsub("%s*%b[]", ""):gsub("%s*%b()", "")
    local parts = {}
    for p in (name .. " - "):gmatch("(.-)%s+%-%s+") do
        p = trim(p)
        if p ~= "" then parts[#parts + 1] = p end
    end
    local out = {}
    if #parts >= 2 then
        out.author = parts[1]
        out.title = parts[#parts]
        if #parts >= 3 then
            local mid = parts[2]
            local sname, num = mid:match("^(.-)%s*[#%[]?(%d+%.?%d*)%]?$")
            if sname and sname ~= "" then
                out.series, out.series_num = trim(sname), tonumber(num)
            else
                out.series = mid
            end
        end
    else
        out.title = trim(name)
    end
    -- "Title (Series #3)" style
    if not out.series then
        local sname, num = (entry.title or ""):match("%(([^()]-)%s*#%s*(%d+)%)")
        if sname and sname ~= "" then out.series, out.series_num = trim(sname), tonumber(num) end
    end
    return out
end

--- IRC search for the book after this one in its series, e.g.
-- "Brandon Sanderson Mistborn 02".
function M.nextInSeriesQuery(p)
    local q = p.series .. " " .. string.format("%02d", (p.series_num or 0) + 1)
    if p.author then q = p.author .. " " .. q end
    return q
end

--- Bots in the list with their result counts, most results first.
function M.bots(list)
    local counts, out = {}, {}
    for _, e in ipairs(list) do
        if e.bot then
            if not counts[e.bot] then out[#out + 1] = e.bot end
            counts[e.bot] = (counts[e.bot] or 0) + 1
        end
    end
    table.sort(out, function(a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a:lower() < b:lower()
    end)
    local res = {}
    for i, b in ipairs(out) do res[i] = { bot = b, count = counts[b] } end
    return res
end

--- Only results from bot (case-insensitive); "" or nil keeps all.
function M.filterBot(list, bot)
    if not bot or bot == "" then return list end
    local out, b = {}, bot:lower()
    for _, e in ipairs(list) do
        if (e.bot or ""):lower() == b then out[#out + 1] = e end
    end
    return out
end

--- Drop results the device can't open. can_open(ext) -> bool. Zips stay
-- when their inner format (or an unknown one) can be opened, since a zip
-- holding one book is unpacked. Returns kept, number hidden.
function M.filterOpenable(list, can_open)
    local out, hidden = {}, 0
    for _, e in ipairs(list) do
        local ext = M.bookExt(e)
        local ok = true
        if ext and ext ~= "zip" then ok = can_open(ext) end
        if ok then out[#out + 1] = e else hidden = hidden + 1 end
    end
    return out, hidden
end

--- "EPUB · 1.2 MB" for the results list.
function M.badge(entry)
    local ext = M.bookExt(entry)
    local parts = {}
    if ext then parts[#parts + 1] = ext:upper() end
    if entry.size then parts[#parts + 1] = entry.size end
    return table.concat(parts, " · ")
end

--- "1.2MB", "950,3 KB", "3 GB" or "12345" to a number of bytes, or nil.
function M.sizeBytes(size)
    if not size then return nil end
    local num, unit = tostring(size):gsub(",", "."):match("([%d%.]+)%s*([KMGkmg]?)")
    num = tonumber(num)
    if not num then return nil end
    unit = unit:lower()
    if unit == "k" then num = num * 1024
    elseif unit == "m" then num = num * 1048576
    elseif unit == "g" then num = num * 1073741824 end
    return math.floor(num + 0.5)
end

--- "epub, mobi pdf" to { "epub", "mobi", "pdf" }.
function M.parseFormats(s)
    local out, seen = {}, {}
    for f in tostring(s or ""):lower():gmatch("[%w]+") do
        if not seen[f] then
            seen[f] = true
            out[#out + 1] = f
        end
    end
    return out
end

--- Format of the book inside an entry: "Title.epub.zip" counts as epub.
function M.bookExt(entry)
    local ext = entry.ext
    if ext == "zip" then
        local inner = entry.title:match("%.(%w+)%.[Zz][Ii][Pp]$")
        if inner then return inner:lower() end
    end
    return ext
end

--- Position of an entry's format in the preferred list (1 is best). Other
-- formats come after the preferred ones, and archives KOReader cannot open
-- come last.
function M.formatRank(entry, prefs)
    local ext = M.bookExt(entry)
    if ext and M.ARCHIVES[ext] then return 1000 end
    for i, f in ipairs(prefs or {}) do
        if f == ext then return i end
    end
    return #(prefs or {}) + 1
end

--- Keep only entries no larger than max_bytes. Entries without a size stay.
function M.filterSize(list, max_bytes)
    if not max_bytes or max_bytes <= 0 then return list end
    local out = {}
    for _, e in ipairs(list) do
        local n = M.sizeBytes(e.size)
        if not n or n <= max_bytes then out[#out + 1] = e end
    end
    return out
end

M.SORTS = { "format", "size_asc", "size_desc", "name", "none" }

--- Sorted copy of list. mode: "format" (preferred format first, then as
-- received), "size_asc", "size_desc", "name" or "none" (as received).
function M.sort(list, mode, prefs)
    local out, pos = {}, {}
    for i, e in ipairs(list) do
        out[i] = e
        pos[e] = i
    end
    if mode == nil or mode == "none" then return out end
    local function key(e)
        if mode == "format" then return M.formatRank(e, prefs) end
        if mode == "size_asc" then return M.sizeBytes(e.size) or math.huge end
        if mode == "size_desc" then return -(M.sizeBytes(e.size) or -1) end
        if mode == "name" then return e.title:lower() end
        return 0
    end
    local keys = {}
    for _, e in ipairs(out) do keys[e] = key(e) end
    table.sort(out, function(a, b)
        local ka, kb = keys[a], keys[b]
        if ka ~= kb then return ka < kb end
        return pos[a] < pos[b]
    end)
    return out
end

return M
