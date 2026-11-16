--[[--
Export and import of book lists as one JSON file: the Want to read shelf,
followed series (with their books), the other saved Hardcover lists and
followed authors. Used to move lists to another device, share them, or keep
a copy; an imported file can be downloaded in the background, added to Want
to read on Hardcover, and its authors followed.

No KOReader dependencies, so it is tested in spec/run.lua. json: an object
with encode and decode (KOReader's json or rapidjson).
]]

local M = {}

M.FORMAT = "ircbooks-lists"
M.VERSION = 1
M.PREFIX = "ircbooks-lists"

local function str(v)
    if type(v) == "string" and v ~= "" then return v end
end

--- The fields of a book worth keeping in the file.
function M.book(b)
    if type(b) ~= "table" or not str(b.title) then return nil end
    return {
        title = b.title,
        author = str(b.author),
        authors = str(b.authors),
        id = tonumber(b.id),
        series = str(b.series),
        series_name = str(b.series_name),
        series_pos = tonumber(b.series_pos),
        release_year = tonumber(b.release_year),
    }
end

local function books(list)
    local out = {}
    for _i, b in ipairs(type(list) == "table" and list or {}) do
        local x = M.book(b)
        if x then out[#out + 1] = x end
    end
    return out
end

--- Build the table to save. data: { want = books, series = {{id, name,
-- books}}, lists = {{id, name, books}}, authors = {{name, id}}, now }.
function M.build(data)
    local out = {
        format = M.FORMAT,
        version = M.VERSION,
        exported = os.date("!%Y-%m-%dT%H:%M:%SZ", data.now or os.time()),
        want_to_read = books(data.want),
        series = {},
        lists = {},
        authors = {},
    }
    for _i, sr in ipairs(data.series or {}) do
        if str(sr.name) then
            out.series[#out.series + 1] = { name = sr.name, id = tonumber(sr.id), books = books(sr.books) }
        end
    end
    for _i, l in ipairs(data.lists or {}) do
        if str(l.name) then
            out.lists[#out.lists + 1] = { name = l.name, id = tonumber(l.id), books = books(l.books) }
        end
    end
    for _i, a in ipairs(data.authors or {}) do
        if str(a.name) then out.authors[#out.authors + 1] = { name = a.name, id = tonumber(a.id) } end
    end
    return out
end

function M.encode(json, data)
    return json.encode(M.build(data))
end

--- Read a file's text. Returns the data (cleaned) or nil, error.
-- Also takes a plain text file with one "Author - Title" or "Title by
-- Author" per line, as a Want to read list.
function M.parse(json, text)
    text = tostring(text or ""):gsub("^\239\187\191", "")
    local first = text:match("^%s*(.)")
    if first == "{" then
        local ok, d = pcall(json.decode, text)
        if not ok or type(d) ~= "table" then return nil, "The file is not valid JSON." end
        if d.format ~= M.FORMAT then return nil, "This is not a book list exported by this plugin." end
        local out = { want_to_read = books(d.want_to_read), series = {}, lists = {}, authors = {}, exported = str(d.exported) }
        for _i, sr in ipairs(type(d.series) == "table" and d.series or {}) do
            if type(sr) == "table" and str(sr.name) then
                out.series[#out.series + 1] = { name = sr.name, id = tonumber(sr.id), books = books(sr.books) }
            end
        end
        for _i, l in ipairs(type(d.lists) == "table" and d.lists or {}) do
            if type(l) == "table" and str(l.name) then
                out.lists[#out.lists + 1] = { name = l.name, id = tonumber(l.id), books = books(l.books) }
            end
        end
        for _i, a in ipairs(type(d.authors) == "table" and d.authors or {}) do
            if type(a) == "table" and str(a.name) then out.authors[#out.authors + 1] = { name = a.name, id = tonumber(a.id) } end
        end
        return out
    end
    -- Plain text: one book per line.
    local want = {}
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s*[%-%*•]%s+", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            local title, author = line:match("^(.-)%s+by%s+(.+)$")
            if not title then
                author, title = line:match("^(.-)%s+%-%s+(.+)$")
            end
            if title and title ~= "" then
                want[#want + 1] = { title = title, author = author, authors = author }
            else
                want[#want + 1] = { title = line }
            end
        end
    end
    if #want == 0 then return nil, "No books found in this file." end
    return { want_to_read = want, series = {}, lists = {}, authors = {} }
end

--- Every book in the file once (by Hardcover id, else title + author),
-- in file order. which: "want", "series", "lists" or nil for all.
function M.allBooks(d, which)
    local out, seen = {}, {}
    local function add(list)
        for _i, b in ipairs(list or {}) do
            local k = b.id and ("id:" .. b.id) or ((b.title or ""):lower() .. "|" .. (b.author or ""):lower())
            if not seen[k] then
                seen[k] = true
                out[#out + 1] = b
            end
        end
    end
    if not which or which == "want" then add(d.want_to_read) end
    if not which or which == "series" then for _i, sr in ipairs(d.series or {}) do add(sr.books) end end
    if not which or which == "lists" then for _i, l in ipairs(d.lists or {}) do add(l.books) end end
    return out
end

--- "12 Want to read · 3 series (40 books) · 2 lists · 5 authors".
function M.summary(d)
    local n = 0
    for _i, sr in ipairs(d.series or {}) do n = n + #(sr.books or {}) end
    local m = 0
    for _i, l in ipairs(d.lists or {}) do m = m + #(l.books or {}) end
    return string.format("%d Want to read · %d series (%d books) · %d lists (%d books) · %d authors",
        #(d.want_to_read or {}), #(d.series or {}), n, #(d.lists or {}), m, #(d.authors or {}))
end

return M
