--[[--
Hardcover (hardcover.app) client and local file matching.

Talks to Hardcover's GraphQL API to read the user's lists and "Want to read"
shelf, and works out which of those books already have a file on the device.

No KOReader dependencies: the HTTP transport, JSON codec and filesystem
access are passed in, so this can be tested on a desktop.
]]

local M = {}

M.ENDPOINT = "https://api.hardcover.app/v1/graphql"

M.STATUS_WANT_TO_READ = 1
M.STATUS_READING = 2
M.STATUS_READ = 3

local BOOK_FIELDS = [[
      id
      title
      contributions { author { name } }
      book_series { position series { name } }
]]

local LISTS_QUERY = [[
query IrcBooksLists {
  me {
    id
    username
    lists(order_by: {name: asc}) { id name books_count }
  }
}]]

local LIST_BOOKS_QUERY = [[
query IrcBooksListBooks($id: Int!) {
  lists(where: {id: {_eq: $id}}) {
    id
    name
    list_books(order_by: {position: asc}) {
      position
      book {]] .. BOOK_FIELDS .. [[
      }
    }
  }
}]]

local STATUS_BOOKS_QUERY = [[
query IrcBooksStatusBooks($status: Int!) {
  me {
    user_books(where: {status_id: {_eq: $status}}, order_by: {updated_at: desc}) {
      book {]] .. BOOK_FIELDS .. [[
      }
    }
  }
}]]

-- Series the user follows (Series Tracker → Following) and series of books
-- they are reading or have read (Series Tracker → All).
local SERIES_QUERY = [[
query IrcBooksSeries {
  me {
    follows { followable_type series { id name primary_books_count } }
    user_books(where: {status_id: {_in: [2, 3]}}) {
      book { book_series { series { id name primary_books_count } } }
    }
  }
}]]

local SERIES_BOOKS_QUERY = [[
query IrcBooksSeriesBooks($id: Int!) {
  series(where: {id: {_eq: $id}}) {
    id
    name
    book_series(
      where: {position: {_is_null: false}, compilation: {_eq: false}, book: {canonical_id: {_is_null: true}}}
      order_by: [{position: asc}, {book: {users_count: desc}}]
    ) {
      position
      book {]] .. BOOK_FIELDS .. [[
      }
    }
  }
}]]

local USER_BOOK_QUERY = [[
query IrcBooksUserBook($book: Int!) {
  me {
    user_books(where: {book_id: {_eq: $book}}) { id status_id }
  }
}]]

local INSERT_USER_BOOK = [[
mutation IrcBooksInsertUserBook($book: Int!, $status: Int!) {
  insert_user_book(object: {book_id: $book, status_id: $status}) { id error }
}]]

local UPDATE_USER_BOOK = [[
mutation IrcBooksUpdateUserBook($id: Int!, $status: Int!) {
  update_user_book(id: $id, object: {status_id: $status}) { id error }
}]]

--- The API key as Hardcover shows it may already start with "Bearer".
function M.cleanToken(token)
    token = tostring(token or "")
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    token = token:gsub("^[Bb]earer%s+", "")
    token = token:gsub("%s", "")
    return token
end

--- opts:
--   post(url, headers, body) -> status_code, response_body | nil, error
--   json = { encode = fn, decode = fn }
--   token = string or function returning the API key
function M.new(opts)
    local self = setmetatable({}, { __index = M })
    self.post = opts.post
    self.json = opts.json
    self.token = opts.token
    return self
end

function M:getToken()
    local t = self.token
    if type(t) == "function" then t = t() end
    return M.cleanToken(t)
end

local function isTable(v) return type(v) == "table" end
local function isString(v) return type(v) == "string" end

--- Run a GraphQL query. Returns data or nil, error message.
function M:query(query, variables)
    local token = self:getToken()
    if token == "" then return nil, "No Hardcover API key is set." end
    local payload = { query = query }
    if variables then payload.variables = variables end
    local ok, body = pcall(self.json.encode, payload)
    if not ok then return nil, "Could not encode request: " .. tostring(body) end
    local code, resp = self.post(M.ENDPOINT, {
        ["content-type"] = "application/json",
        ["accept"] = "application/json",
        ["authorization"] = "Bearer " .. token,
        ["user-agent"] = "ircbooks.koplugin (KOReader)",
        ["content-length"] = tostring(#body),
    }, body)
    if not code then
        return nil, "Could not reach Hardcover: " .. tostring(resp)
    end
    code = tonumber(code)
    if code == 401 or code == 403 then
        return nil, "Hardcover did not accept the API key. Copy a fresh one from hardcover.app/account/api."
    end
    local decoded
    if isString(resp) and resp ~= "" then
        local dok, d = pcall(self.json.decode, resp)
        if dok then decoded = d end
    elseif isTable(resp) then
        decoded = resp
    end
    if isTable(decoded) and isTable(decoded.errors) and decoded.errors[1] then
        local msg = decoded.errors[1].message
        msg = isString(msg) and msg or "unknown error"
        if msg:lower():find("jwt") or msg:lower():find("auth") then
            return nil, "Hardcover did not accept the API key (" .. msg .. ")."
        end
        return nil, "Hardcover error: " .. msg
    end
    if code ~= 200 then
        return nil, "Hardcover answered with HTTP " .. tostring(code) .. "."
    end
    if not isTable(decoded) or not isTable(decoded.data) then
        return nil, "Unexpected answer from Hardcover."
    end
    return decoded.data
end

-- Hasura returns `me` as an array with one row.
local function firstRow(v)
    if not isTable(v) then return nil end
    if v[1] ~= nil then return isTable(v[1]) and v[1] or nil end
    return v
end

--- Turn a Hardcover book row into {id, title, authors, author, series}.
function M.normalizeBook(row)
    if not isTable(row) then return nil end
    local title = isString(row.title) and row.title or nil
    if not title or title == "" then return nil end
    local names = {}
    if isTable(row.contributions) then
        for _, c in ipairs(row.contributions) do
            local name = isTable(c) and isTable(c.author) and c.author.name
            if isString(name) and name ~= "" then
                local dup = false
                for _, n in ipairs(names) do if n == name then dup = true break end end
                if not dup then names[#names + 1] = name end
            end
        end
    end
    local series
    if isTable(row.book_series) then
        for _, bs in ipairs(row.book_series) do
            local sname = isTable(bs) and isTable(bs.series) and bs.series.name
            if isString(sname) and sname ~= "" then
                local pos = tonumber(bs.position)
                if pos then
                    if pos == math.floor(pos) then pos = string.format("%d", pos) end
                    series = sname .. " #" .. tostring(pos)
                else
                    series = sname
                end
                break
            end
        end
    end
    return {
        id = tonumber(row.id) or row.id,
        title = title,
        authors = table.concat(names, ", "),
        author = names[1],
        series = series,
    }
end

--- Returns {user = {id, username}, lists = {{id, name, count}}} or nil, err.
function M:getLists()
    local data, err = self:query(LISTS_QUERY)
    if not data then return nil, err end
    local me = firstRow(data.me)
    if not me then return nil, "Hardcover returned no user for this API key." end
    local lists = {}
    if isTable(me.lists) then
        for _, l in ipairs(me.lists) do
            if isTable(l) and l.id and isString(l.name) then
                lists[#lists + 1] = { id = tonumber(l.id) or l.id, name = l.name, count = tonumber(l.books_count) }
            end
        end
    end
    return { user = { id = me.id, username = isString(me.username) and me.username or nil }, lists = lists }
end

local function collectBooks(rows, key)
    local books, seen = {}, {}
    if not isTable(rows) then return books end
    for _, r in ipairs(rows) do
        local b = M.normalizeBook(isTable(r) and r[key])
        if b and not seen[b.id or b.title] then
            seen[b.id or b.title] = true
            books[#books + 1] = b
        end
    end
    return books
end

--- Books of one list, in list order.
function M:getListBooks(list_id)
    local data, err = self:query(LIST_BOOKS_QUERY, { id = tonumber(list_id) or list_id })
    if not data then return nil, err end
    local list = firstRow(data.lists)
    if not list then return nil, "That list was not found on Hardcover." end
    return collectBooks(list.list_books, "book")
end

--- Books on a reading status shelf (1 = Want to read).
function M:getStatusBooks(status_id)
    local data, err = self:query(STATUS_BOOKS_QUERY, { status = status_id })
    if not data then return nil, err end
    local me = firstRow(data.me)
    if not me then return nil, "Hardcover returned no user for this API key." end
    return collectBooks(me.user_books, "book")
end

local function seriesEntry(sr)
    if not isTable(sr) or not sr.id or not isString(sr.name) then return nil end
    return { id = tonumber(sr.id) or sr.id, name = sr.name, count = tonumber(sr.primary_books_count) }
end

--- Returns {following = {...}, started = {...}} of {id, name, count}.
-- "started" leaves out series that are also followed.
function M:getSeries()
    local data, err = self:query(SERIES_QUERY)
    if not data then return nil, err end
    local me = firstRow(data.me)
    if not me then return nil, "Hardcover returned no user for this API key." end
    local following, started, seen = {}, {}, {}
    if isTable(me.follows) then
        for _, f in ipairs(me.follows) do
            local e = isTable(f) and seriesEntry(f.series)
            if e and not seen[e.id] then
                seen[e.id] = true
                following[#following + 1] = e
            end
        end
    end
    if isTable(me.user_books) then
        for _, ub in ipairs(me.user_books) do
            local bs = isTable(ub) and isTable(ub.book) and ub.book.book_series
            if isTable(bs) then
                for _, x in ipairs(bs) do
                    local e = isTable(x) and seriesEntry(x.series)
                    if e and not seen[e.id] then
                        seen[e.id] = true
                        started[#started + 1] = e
                    end
                end
            end
        end
    end
    local function byName(a, b) return a.name:lower() < b.name:lower() end
    table.sort(following, byName)
    table.sort(started, byName)
    return { following = following, started = started }
end

--- The user's shelf entry for a book: {id, status_id}, false when the book
-- is not on any shelf, or nil, err.
function M:getUserBook(book_id)
    local data, err = self:query(USER_BOOK_QUERY, { book = tonumber(book_id) or book_id })
    if not data then return nil, err end
    local me = firstRow(data.me)
    if not me then return nil, "Hardcover returned no user for this API key." end
    local ub = isTable(me.user_books) and me.user_books[1]
    if not isTable(ub) or not ub.id then return false end
    return { id = tonumber(ub.id) or ub.id, status_id = tonumber(ub.status_id) }
end

local function mutationResult(data, key)
    local r = isTable(data) and data[key]
    if isTable(r) and isString(r.error) and r.error ~= "" then
        return nil, "Hardcover error: " .. r.error
    end
    return true
end

--- Set a book's reading status (2 = Currently reading, 3 = Read).
-- Returns "set", "unchanged" (already on that status), "kept" (already Read,
-- so not moved back to Currently reading), or nil, err.
function M:setStatus(book_id, status_id)
    local ub, err = self:getUserBook(book_id)
    if ub == nil then return nil, err end
    if ub and ub.status_id == status_id then return "unchanged" end
    if ub and status_id == M.STATUS_READING and ub.status_id == M.STATUS_READ then return "kept" end
    local data, ok
    if ub then
        data, err = self:query(UPDATE_USER_BOOK, { id = ub.id, status = status_id })
        if not data then return nil, err end
        ok, err = mutationResult(data, "update_user_book")
    else
        data, err = self:query(INSERT_USER_BOOK, { book = tonumber(book_id) or book_id, status = status_id })
        if not data then return nil, err end
        ok, err = mutationResult(data, "insert_user_book")
    end
    if not ok then return nil, err end
    return "set"
end

--- Primary books of a series (whole-number positions), one per position.
function M:getSeriesBooks(series_id)
    local data, err = self:query(SERIES_BOOKS_QUERY, { id = tonumber(series_id) or series_id })
    if not data then return nil, err end
    local sr = firstRow(data.series)
    if not sr then return nil, "That series was not found on Hardcover." end
    local books, have_pos = {}, {}
    if isTable(sr.book_series) then
        for _, bs in ipairs(sr.book_series) do
            local pos = isTable(bs) and tonumber(bs.position)
            if pos and pos == math.floor(pos) and not have_pos[pos] then
                local b = M.normalizeBook(bs.book)
                if b then
                    have_pos[pos] = true
                    b.series = sr.name .. " #" .. string.format("%d", pos)
                    books[#books + 1] = b
                end
            end
        end
    end
    return books
end

-------------------------------------------------------------------------------
-- Matching books with files on the device
-------------------------------------------------------------------------------

M.BOOK_EXTS = {
    epub = true, mobi = true, azw = true, azw3 = true, pdf = true, fb2 = true,
    djvu = true, txt = true, rtf = true, doc = true, docx = true, lit = true,
    cbz = true, cbr = true, pdb = true, prc = true, kepub = true, zip = true,
}

-- Latin letters with accents, as UTF-8, folded to ASCII.
local ACCENTS = {
    ["à"]="a", ["á"]="a", ["â"]="a", ["ã"]="a", ["ä"]="a", ["å"]="a",
    ["ç"]="c", ["è"]="e", ["é"]="e", ["ê"]="e", ["ë"]="e",
    ["ì"]="i", ["í"]="i", ["î"]="i", ["ï"]="i", ["ñ"]="n",
    ["ò"]="o", ["ó"]="o", ["ô"]="o", ["õ"]="o", ["ö"]="o", ["ø"]="o",
    ["ù"]="u", ["ú"]="u", ["û"]="u", ["ü"]="u", ["ý"]="y", ["ÿ"]="y",
    ["ß"]="ss", ["æ"]="ae", ["œ"]="oe",
}

--- Lowercase ASCII words separated by single spaces.
function M.normalize(s)
    s = tostring(s or ""):lower()
    s = s:gsub("[\195\197][\128-\191]", function(ch) return ACCENTS[ch] or ch end)
    s = s:gsub("[\195][\128-\159]", function(ch)
        -- uppercase accented letters: lower() leaves them alone
        local lowered = string.char(195, ch:byte(2) + 32)
        return ACCENTS[lowered] or ch
    end)
    s = s:gsub("&", " and ")
    s = s:gsub("'", "")
    s = s:gsub("’", "")
    s = s:gsub("[^%w]+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local STOPWORDS = {
    the = true, a = true, an = true, ["and"] = true, of = true, ["in"] = true,
    on = true, to = true, ["for"] = true, at = true, by = true, with = true,
    from = true, le = true, la = true, les = true, der = true, die = true, das = true,
}

local function words(s)
    local list = {}
    for w in M.normalize(s):gmatch("%S+") do
        if not STOPWORDS[w] then list[#list + 1] = w end
    end
    return list
end

local function wordSet(s)
    local set = {}
    for w in M.normalize(s):gmatch("%S+") do set[w] = true end
    return set
end

local function allIn(list, set)
    if #list == 0 then return false end
    for _, w in ipairs(list) do if not set[w] then return false end end
    return true
end

local function surname(author)
    local w = {}
    for x in M.normalize(author):gmatch("%S+") do w[#w + 1] = x end
    -- Skip suffixes such as "Jr".
    for i = #w, 1, -1 do
        if #w[i] > 2 and w[i] ~= "jr" and w[i] ~= "sr" then return w[i] end
    end
    return w[#w]
end

--- Make a lookup entry for a file: {path, set}. meta (optional) holds the
-- book's own title and authors, e.g. from KOReader's book info, whose words
-- count as well as those of the file name.
function M.fileEntry(path, meta)
    local name = path:match("([^/\\]+)$") or path
    name = name:gsub("%.[%w]+$", "")
    if type(meta) == "table" then
        local extra = {}
        if isString(meta.title) then extra[#extra + 1] = meta.title end
        if isString(meta.authors) then extra[#extra + 1] = meta.authors end
        if #extra > 0 then name = name .. " " .. table.concat(extra, " ") end
    end
    return { path = path, set = wordSet(name) }
end

--- True when a file name looks like this book.
-- The words of the title must all appear in the name (or, for titles with a
-- colon, all words of either part when that part is specific enough), and for
-- short titles the author's surname must appear too.
function M.matches(book, file)
    local set = file.set
    local title = book.title or ""
    local candidates = { words(title) }
    local main, sub = title:match("^(.-)%s*:%s*(.+)$")
    if main then
        local mw, sw = words(main), words(sub)
        if #mw >= 2 then candidates[#candidates + 1] = mw end
        if #sw >= 2 then candidates[#candidates + 1] = sw end
    end
    local paren = title:gsub("%s*%b()", "")
    if paren ~= title then candidates[#candidates + 1] = words(paren) end
    local sname = book.author and surname(book.author)
    for _, c in ipairs(candidates) do
        if allIn(c, set) then
            if #c >= 3 then return true end
            if not sname or set[sname] then return true end
        end
    end
    return false
end

--- First matching file entry for a book, or nil.
function M.findFile(book, files)
    for _, f in ipairs(files) do
        if M.matches(book, f) then return f.path end
    end
end

--- Walk folders and return file entries for book files.
-- lfs: LuaFileSystem-like {dir, attributes}; roots: array of folder paths;
-- meta (optional): function(path) returning {title, authors} or nil.
function M.scan(lfs, roots, max_depth, max_files, meta)
    max_depth = max_depth or 4
    max_files = max_files or 20000
    local files, seen_dirs = {}, {}
    local function walk(dir, depth)
        if #files >= max_files or seen_dirs[dir] then return end
        seen_dirs[dir] = true
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok or not iter then return end
        for name in iter, state do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    if depth < max_depth and not name:match("%.sdr$") then walk(path, depth + 1) end
                elseif mode == "file" then
                    local ext = (name:match("%.([%w]+)$") or ""):lower()
                    if M.BOOK_EXTS[ext] then
                        local m
                        if meta then
                            local ok, r = pcall(meta, path)
                            if ok then m = r end
                        end
                        files[#files + 1] = M.fileEntry(path, m)
                        if #files >= max_files then return end
                    end
                end
            end
        end
    end
    for _, root in ipairs(roots) do
        if root and root ~= "" then walk((root:gsub("/+$", "")), 0) end
    end
    return files
end

--- First book in books that matches a file entry. Used to find which
-- Hardcover book an opened file is.
function M.findBook(file, books)
    for _, b in ipairs(books) do
        if M.matches(b, file) then return b end
    end
end

-------------------------------------------------------------------------------
-- Picking the IRC result that best matches a book
-------------------------------------------------------------------------------

--- Score how well an IRC result matches a book, or nil when it does not
-- match. Higher is better: all title words count most, then the author's
-- surname; extra words (other books, omnibus editions) count against it.
function M.resultScore(book, entry)
    local name = entry.title:gsub("%.[Zz][Ii][Pp]$", ""):gsub("%.[%w]+$", "")
    local file = { set = wordSet(name) }
    if not M.matches(book, file) then return nil end
    local score = 10
    local sname = book.author and surname(book.author)
    if sname and file.set[sname] then score = score + 5 end
    local own = wordSet((book.title or "") .. " " .. (book.authors or book.author or ""))
    local extra = 0
    for w in pairs(file.set) do
        if not own[w] and not STOPWORDS[w] and not w:match("^%d+$") then extra = extra + 1 end
    end
    return score - math.min(extra, 8) * 0.5
end

--- Results that match the book, best first. rank(entry) (optional) returns a
-- number where lower is better, e.g. the preferred-format position; it breaks
-- ties between equally good matches.
function M.rankResults(book, list, rank)
    local scored = {}
    for i, e in ipairs(list) do
        local sc = M.resultScore(book, e)
        if sc then scored[#scored + 1] = { e = e, sc = sc, r = rank and rank(e) or 0, i = i } end
    end
    table.sort(scored, function(a, b)
        -- A much better title match wins over format; otherwise format first.
        if math.abs(a.sc - b.sc) >= 2 then return a.sc > b.sc end
        if a.r ~= b.r then return a.r < b.r end
        if a.sc ~= b.sc then return a.sc > b.sc end
        return a.i < b.i
    end)
    local out = {}
    for k, s in ipairs(scored) do out[k] = s.e end
    return out
end

--- Text to send to the IRC search bot for a book: author and title, without
-- punctuation and without a long subtitle.
function M.searchQuery(book)
    local title = book.title or ""
    local main, sub = title:match("^(.-)%s*:%s*(.+)$")
    if main and main ~= "" then
        local n = 0
        for _ in sub:gmatch("%S+") do n = n + 1 end
        if n > 4 then title = main end
    end
    title = title:gsub("%s*%b()", "")
    local parts = {}
    if book.author and book.author ~= "" then parts[#parts + 1] = book.author end
    parts[#parts + 1] = title
    local q = table.concat(parts, " ")
    q = q:gsub("[%[%]%(%){}:;,!%?\"“”]", " "):gsub("%s+", " ")
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    return q
end

return M
