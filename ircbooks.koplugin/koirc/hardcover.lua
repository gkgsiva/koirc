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
M.STATUS_PAUSED = 4
M.STATUS_DNF = 5

local BOOK_FIELDS = [[
      id
      title
      pages
      rating
      ratings_count
      release_year
      description
      image { url }
      contributions { author { name } }
      book_series { position series { id name } }
]]

local LISTS_QUERY = [[
query IrcBooksLists {
  me {
    id
    username
    lists(order_by: {name: asc}) { id name books_count updated_at }
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
    user_books(where: {book_id: {_eq: $book}}) {
      id
      status_id
      user_book_reads(order_by: {id: desc}, limit: 1) { id started_at finished_at edition_id progress_pages }
    }
  }
}]]

local INSERT_READ = [[
mutation IrcBooksInsertRead($ub: Int!, $read: DatesReadInput!) {
  insert_user_book_read(user_book_id: $ub, user_book_read: $read) { id error }
}]]

local UPDATE_READ = [[
mutation IrcBooksUpdateRead($id: Int!, $read: DatesReadInput!) {
  update_user_book_read(id: $id, object: $read) { id error }
}]]

local RATE_USER_BOOK = [[
mutation IrcBooksRateUserBook($id: Int!, $object: UserBookUpdateInput!) {
  update_user_book(id: $id, object: $object) { id error }
}]]

-- Authors the user follows (follows with followable_type "Author").
local FOLLOWED_AUTHORS_QUERY = [[
query IrcBooksFollowedAuthors {
  me {
    follows(where: {followable_type: {_eq: "Author"}}) { followable_id author { id name } }
  }
}]]

-- Recent and upcoming books by some authors.
local AUTHOR_BOOKS_QUERY = [[
query IrcBooksAuthorBooks($ids: [Int!], $since: date!) {
  books(
    where: {contributions: {author_id: {_in: $ids}}, release_date: {_gte: $since}, canonical_id: {_is_null: true}}
    order_by: {release_date: desc}
    limit: 100
  ) {
    release_date]] .. BOOK_FIELDS .. [[
  }
}]]

local SEARCH_QUERY = [[
query IrcBooksSearch($q: String!) {
  search(query: $q, query_type: "Book", per_page: 8, page: 1) { results }
}]]

local INSERT_LIST_BOOK = [[
mutation IrcBooksInsertListBook($list: Int!, $book: Int!) {
  insert_list_book(object: {list_id: $list, book_id: $book}) { id }
}]]

local INSERT_USER_BOOK = [[
mutation IrcBooksInsertUserBook($book: Int!, $status: Int!) {
  insert_user_book(object: {book_id: $book, status_id: $status}) { id error }
}]]

local UPDATE_USER_BOOK = [[
mutation IrcBooksUpdateUserBook($id: Int!, $status: Int!) {
  update_user_book(id: $id, object: {status_id: $status}) { id error }
}]]

-- Several lists or series in one request, to keep the number of requests
-- low (Hardcover allows about 60 a minute).
local LISTS_BOOKS_QUERY = [[
query IrcBooksListsBooks($ids: [Int!]) {
  lists(where: {id: {_in: $ids}}) {
    id
    list_books(order_by: {position: asc}) {
      position
      book {]] .. BOOK_FIELDS .. [[
      }
    }
  }
}]]

local SERIES_MANY_QUERY = [[
query IrcBooksSeriesMany($ids: [Int!]) {
  series(where: {id: {_in: $ids}}) {
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

local BOOK_QUERY = [[
query IrcBooksBook($id: Int!) {
  books(where: {id: {_eq: $id}}) {]] .. BOOK_FIELDS .. [[
  }
}]]

-- Genres and other tags of some books (for auto-tagging files).
local BOOK_TAGS_QUERY = [[
query IrcBooksTags($ids: [Int!]) {
  books(where: {id: {_in: $ids}}) { id cached_tags }
}]]

-- The user's reading goals (Hardcover → Goals).
local GOALS_QUERY = [[
query IrcBooksGoals {
  me {
    goals(where: {archived: {_eq: false}}, order_by: {end_date: desc}, limit: 5) {
      id goal metric progress start_date end_date description
    }
  }
}]]

-- Requests are spaced out and limited per minute for every client in this
-- KOReader session (and each background process has its own copy).
-- busy_until: Hardcover said "too many requests"; nothing is sent before.
local Rate = { stamps = {}, busy_until = 0 }
M.Rate = Rate
M.PER_MINUTE = 50
M.MIN_GAP = 0.6
M.BUSY = "Hardcover is busy (too many requests)."

--- Was err caused by Hardcover's rate limit?
function M.isBusy(err)
    return type(err) == "string" and err:find(M.BUSY, 1, true) ~= nil
end

--- Forget the request history (tests).
function M.resetRate()
    Rate.stamps = {}
    Rate.busy_until = 0
end

--- Seconds from a Retry-After header ("120" or an HTTP date), or nil.
function M.retryAfter(headers, now_epoch)
    if type(headers) ~= "table" then return nil end
    local v = headers["retry-after"] or headers["Retry-After"]
    if v == nil then return nil end
    v = tostring(v)
    local n = tonumber(v)
    if n then return math.max(0, n) end
    local months = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
    local d, mon, y, h, mi, sec = v:match("(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")
    if d and months[mon] then
        local t = os.time{ year = tonumber(y), month = months[mon], day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) }
        -- os.time reads local time; the header is GMT.
        local now = now_epoch or os.time()
        local utc_offset = os.time(os.date("*t", now)) - os.time(os.date("!*t", now))
        return math.max(0, t + utc_offset - now)
    end
    return nil
end

--- The API key as Hardcover shows it may already start with "Bearer".
function M.cleanToken(token)
    token = tostring(token or "")
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    token = token:gsub("^[Bb]earer%s+", "")
    token = token:gsub("%s", "")
    return token
end

--- opts:
--   post(url, headers, body) -> status_code, response_body, response_headers
--                               | nil, error
--   json = { encode = fn, decode = fn }
--   token = string or function returning the API key
--   sleep(seconds), now() -> seconds: when given, requests are spaced out
--     (M.MIN_GAP, M.PER_MINUTE) and a "too many requests" answer is retried
--     after the wait Hardcover asks for, if it is no longer than max_wait.
--   max_wait: longest single wait in seconds (default 20)
function M.new(opts)
    local self = setmetatable({}, { __index = M })
    self.post = opts.post
    self.json = opts.json
    self.token = opts.token
    self.sleep = opts.sleep
    self.now = opts.now or os.time
    self.max_wait = opts.max_wait or 20
    return self
end

--- Wait until another request may be sent. Returns true, or nil and the
-- seconds still to wait when that is longer than max_wait (or there is no
-- way to wait).
function M:waitTurn()
    local now = self.now()
    if Rate.busy_until > now then
        local w = Rate.busy_until - now
        if not self.sleep or w > self.max_wait then return nil, w end
        self.sleep(w)
        now = self.now()
    end
    if not self.sleep then return true end
    local stamps = Rate.stamps
    while stamps[1] and now - stamps[1] >= 60 do table.remove(stamps, 1) end
    local w = 0
    if #stamps >= M.PER_MINUTE then w = stamps[1] + 60 - now end
    local last = stamps[#stamps]
    if last and now - last < M.MIN_GAP then w = math.max(w, M.MIN_GAP - (now - last)) end
    if w > 0 then
        if w > self.max_wait then return nil, w end
        self.sleep(w)
    end
    stamps[#stamps + 1] = self.now()
    return true
end

function M:getToken()
    local t = self.token
    if type(t) == "function" then t = t() end
    return M.cleanToken(t)
end

local function isTable(v) return type(v) == "table" end
local function isString(v) return type(v) == "string" end

--- Run a GraphQL query. Returns data or nil, error message (and, when
-- Hardcover is busy, the seconds it asked us to wait).
function M:query(query, variables)
    local token = self:getToken()
    if token == "" then return nil, "No Hardcover API key is set." end
    local payload = { query = query }
    if variables then payload.variables = variables end
    local ok, body = pcall(self.json.encode, payload)
    if not ok then return nil, "Could not encode request: " .. tostring(body) end
    for attempt = 0, 2 do
        local turn, wait = self:waitTurn()
        if not turn then return nil, M.BUSY, wait end
        local data, err, retry = self:queryOnce(token, body)
        if not retry then return data, err end
        Rate.busy_until = math.max(Rate.busy_until, self.now() + retry)
        if not self.sleep or retry > self.max_wait or attempt == 2 then
            return nil, M.BUSY, retry
        end
    end
end

-- One request. The third value is set when Hardcover is rate limiting:
-- seconds to wait before trying again.
function M:queryOnce(token, body)
    local code, resp, headers = self.post(M.ENDPOINT, {
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
    if code == 429 or code == 503 then
        return nil, M.BUSY, M.retryAfter(headers) or 10
    end
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
        local low = msg:lower()
        if low:find("throttl") or low:find("rate limit") or low:find("too many") then
            return nil, M.BUSY, M.retryAfter(headers) or 10
        end
        if low:find("jwt") or low:find("auth") then
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
    local series, series_id, series_name, series_pos
    if isTable(row.book_series) then
        for _, bs in ipairs(row.book_series) do
            local sname = isTable(bs) and isTable(bs.series) and bs.series.name
            if isString(sname) and sname ~= "" then
                local pos = tonumber(bs.position)
                series_name, series_pos = sname, pos
                series_id = tonumber(bs.series.id)
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
    local cover = isTable(row.image) and isString(row.image.url) and row.image.url ~= "" and row.image.url or nil
    return {
        id = tonumber(row.id) or row.id,
        title = title,
        authors = table.concat(names, ", "),
        author = names[1],
        series = series,
        series_id = series_id,
        series_name = series_name,
        series_pos = series_pos,
        pages = tonumber(row.pages),
        rating = tonumber(row.rating),
        ratings_count = tonumber(row.ratings_count),
        release_year = tonumber(row.release_year),
        cover = cover,
        description = isString(row.description) and row.description or nil,
        release_date = isString(row.release_date) and row.release_date or nil,
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
                lists[#lists + 1] = {
                    id = tonumber(l.id) or l.id, name = l.name, count = tonumber(l.books_count),
                    updated_at = isString(l.updated_at) and l.updated_at or nil,
                }
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

local function mutationResult(data, key)
    local r = isTable(data) and data[key]
    if isTable(r) and isString(r.error) and r.error ~= "" then
        return nil, "Hardcover error: " .. r.error
    end
    return true
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
    local read = isTable(ub.user_book_reads) and ub.user_book_reads[1]
    if isTable(read) and read.id then
        read = {
            id = tonumber(read.id) or read.id,
            started_at = isString(read.started_at) and read.started_at or nil,
            finished_at = isString(read.finished_at) and read.finished_at or nil,
            edition_id = tonumber(read.edition_id),
            progress_pages = tonumber(read.progress_pages),
        }
    else
        read = nil
    end
    return { id = tonumber(ub.id) or ub.id, status_id = tonumber(ub.status_id), read = read }
end

--- Send reading progress: pages read out of the book's page count, from a
-- fraction (0..1). Adds the book as Currently reading if it is on no shelf,
-- and continues the current read (or starts one dated today).
-- Returns "set", "unchanged", or nil, err.
function M:setProgress(book_id, fraction, pages, today)
    pages = tonumber(pages)
    if not pages or pages <= 0 then return nil, "Hardcover has no page count for this book." end
    local progress = math.max(0, math.min(pages, math.floor(fraction * pages + 0.5)))
    local ub, err = self:getUserBook(book_id)
    if ub == nil then return nil, err end
    if not ub then
        local ok
        ok, err = self:setStatus(book_id, M.STATUS_READING)
        if not ok then return nil, err end
        ub, err = self:getUserBook(book_id)
        if not ub then return nil, err or "Could not add the book on Hardcover." end
    end
    -- A finished book keeps its finished read; progress would start a new one.
    if ub.status_id == M.STATUS_READ then return "unchanged" end
    local read = ub.read
    local data, ok
    if read and not read.finished_at then
        if read.progress_pages == progress then return "unchanged" end
        data, err = self:query(UPDATE_READ, { id = read.id, read = {
            progress_pages = progress,
            started_at = read.started_at or today,
            edition_id = read.edition_id,
        } })
        if not data then return nil, err end
        ok, err = mutationResult(data, "update_user_book_read")
    else
        data, err = self:query(INSERT_READ, { ub = ub.id, read = { progress_pages = progress, started_at = today } })
        if not data then return nil, err end
        ok, err = mutationResult(data, "insert_user_book_read")
    end
    if not ok then return nil, err end
    return "set"
end

--- The book after position pos in a series list (lowest higher position).
function M.nextInSeries(books, pos)
    pos = tonumber(pos)
    if not pos then return nil end
    local best
    for _, b in ipairs(books or {}) do
        local p = tonumber(b.series_pos)
        if p and p > pos and (not best or p < tonumber(best.series_pos)) then best = b end
    end
    return best
end

--- Guess author and title from an IRC result such as
-- "Brandon Sanderson - Mistborn 01 - The Final Empire.epub".
function M.entryBook(entry)
    local name = entry.title:gsub("%.[Zz][Ii][Pp]$", ""):gsub("%.[%w]+$", "")
    name = name:gsub("%s*%b()", ""):gsub("%s*%b[]", "")
    local parts = {}
    for p in (name .. " - "):gmatch("(.-)%s+%-%s+") do
        p = p:gsub("^%s+", ""):gsub("%s+$", "")
        if p ~= "" then parts[#parts + 1] = p end
    end
    if #parts >= 2 then return { title = parts[#parts], author = parts[1], authors = parts[1] } end
    return { title = name }
end

--- Set a book's reading status (2 = Currently reading, 3 = Read).
-- Returns "set", "unchanged" (already on that status), "kept" (already Read,
-- so not moved back to Currently reading), or nil, err.
-- force: the user picked the shelf, so move it even from Read.
function M:setStatus(book_id, status_id, force)
    local ub, err = self:getUserBook(book_id)
    if ub == nil then return nil, err end
    if ub and ub.status_id == status_id then return "unchanged" end
    if ub and not force and status_id == M.STATUS_READING and ub.status_id == M.STATUS_READ then return "kept" end
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

--- A plain-text review as the Slate.js document Hardcover stores reviews
-- in: one paragraph per block of text separated by blank lines.
function M.reviewSlate(text)
    text = tostring(text or ""):gsub("\r\n?", "\n")
    local blocks = {}
    for para in (text .. "\n\n"):gmatch("(.-)\n%s*\n") do
        para = para:gsub("^%s+", ""):gsub("%s+$", "")
        if para ~= "" then
            blocks[#blocks + 1] = {
                object = "block", type = "paragraph", data = {},
                children = {{ object = "text", text = para }},
            }
        end
    end
    if #blocks == 0 then return nil end
    return blocks
end

--- Rate a book (0.5 to 5, in halves) and optionally review it. The book is
-- added as Read when it is on no shelf yet. Returns "set" or nil, err.
function M:setRating(book_id, rating, review, today)
    rating = tonumber(rating)
    if rating then rating = math.max(0.5, math.min(5, math.floor(rating * 2 + 0.5) / 2)) end
    local slate = M.reviewSlate(review)
    if not rating and not slate then return "unchanged" end
    local ub, err = self:getUserBook(book_id)
    if ub == nil then return nil, err end
    if not ub then
        local ok
        ok, err = self:setStatus(book_id, M.STATUS_READ)
        if not ok then return nil, err end
        ub, err = self:getUserBook(book_id)
        if not ub then return nil, err or "Could not add the book on Hardcover." end
    end
    local object = {}
    if rating then object.rating = rating end
    if slate then
        object.review_slate = slate
        object.review_has_spoilers = false
        object.reviewed_at = today
    end
    local data
    data, err = self:query(RATE_USER_BOOK, { id = ub.id, object = object })
    if not data then return nil, err end
    local ok
    ok, err = mutationResult(data, "update_user_book")
    if not ok then return nil, err end
    return "set"
end

--- Find books on Hardcover by text (title and author). Returns an array of
-- books as normalizeBook gives them, best match first, or nil, err.
function M:searchBooks(text)
    local data, err = self:query(SEARCH_QUERY, { q = text })
    if not data then return nil, err end
    local res = isTable(data.search) and data.search.results
    if isString(res) then
        local ok, d = pcall(self.json.decode, res)
        res = ok and d or nil
    end
    local hits = isTable(res) and res.hits or {}
    local books = {}
    for _, h in ipairs(isTable(hits) and hits or {}) do
        local d = isTable(h) and h.document
        if isTable(d) and d.id and isString(d.title) then
            local names = {}
            for _, n in ipairs(isTable(d.author_names) and d.author_names or {}) do
                if isString(n) then names[#names + 1] = n end
            end
            local series = isTable(d.series_names) and isString(d.series_names[1]) and d.series_names[1] or nil
            books[#books + 1] = {
                id = tonumber(d.id) or d.id,
                title = d.title,
                authors = table.concat(names, ", "),
                author = names[1],
                series = series,
                pages = tonumber(d.pages),
                cover = isTable(d.image) and isString(d.image.url) and d.image.url or nil,
                release_year = tonumber(d.release_year),
                rating = tonumber(d.rating),
                ratings_count = tonumber(d.ratings_count),
                description = isString(d.description) and d.description or nil,
            }
        end
    end
    return books
end

--- Add a book to one of the user's lists. Returns true or nil, err.
function M:addToList(list_id, book_id)
    local data, err = self:query(INSERT_LIST_BOOK, { list = tonumber(list_id) or list_id, book = tonumber(book_id) or book_id })
    if not data then return nil, err end
    local r = data.insert_list_book
    if not isTable(r) or not r.id then return nil, "Hardcover did not add the book to the list." end
    return true
end

--- Authors the user follows: array of {id, name}.
function M:getFollowedAuthors()
    local data, err = self:query(FOLLOWED_AUTHORS_QUERY)
    if not data then return nil, err end
    local me = firstRow(data.me)
    if not me then return nil, "Hardcover returned no user for this API key." end
    local out, seen = {}, {}
    for _, f in ipairs(isTable(me.follows) and me.follows or {}) do
        local a = isTable(f) and f.author
        local id = isTable(a) and tonumber(a.id) or (isTable(f) and tonumber(f.followable_id))
        if id and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, name = isTable(a) and isString(a.name) and a.name or nil }
        end
    end
    return out
end

--- Books by these authors released on or after since (YYYY-MM-DD),
-- including announced ones, newest first.
function M:getAuthorBooks(ids, since)
    if not ids or #ids == 0 then return {} end
    local data, err = self:query(AUTHOR_BOOKS_QUERY, { ids = ids, since = since })
    if not data then return nil, err end
    local books, seen = {}, {}
    for _, row in ipairs(isTable(data.books) and data.books or {}) do
        local b = M.normalizeBook(row)
        if b and not seen[b.id] then
            seen[b.id] = true
            books[#books + 1] = b
        end
    end
    return books
end

--- Compare books found now with the ids seen before, per followed series or
-- author. known: {[group] = {[id] = true}} (updated in place). A group seen
-- for the first time is only remembered, so the first sync does not flag a
-- whole back catalogue. Returns the new books, each with .why set.
-- groups: array of {key, why, books}.
function M.findNewReleases(known, groups)
    local fresh, flagged = {}, {}
    for _, g in ipairs(groups) do
        local seen = known[g.key]
        local first = seen == nil
        seen = seen or {}
        for _, b in ipairs(g.books or {}) do
            local id = tostring(b.id)
            if not seen[id] then
                seen[id] = true
                if not first and not flagged[id] then
                    flagged[id] = true
                    local copy = {}
                    for k, v in pairs(b) do copy[k] = v end
                    copy.why = g.why
                    fresh[#fresh + 1] = copy
                end
            end
        end
        known[g.key] = seen
    end
    return fresh
end

local function seriesBooksFromRow(sr)
    local books, have_pos = {}, {}
    if isTable(sr.book_series) then
        for _, bs in ipairs(sr.book_series) do
            local pos = isTable(bs) and tonumber(bs.position)
            if pos and pos == math.floor(pos) and not have_pos[pos] then
                local b = M.normalizeBook(bs.book)
                if b then
                    have_pos[pos] = true
                    b.series = sr.name .. " #" .. string.format("%d", pos)
                    b.series_id = tonumber(sr.id) or b.series_id
                    b.series_name = sr.name
                    b.series_pos = pos
                    books[#books + 1] = b
                end
            end
        end
    end
    return books
end

--- Primary books of a series (whole-number positions), one per position.
function M:getSeriesBooks(series_id)
    local data, err = self:query(SERIES_BOOKS_QUERY, { id = tonumber(series_id) or series_id })
    if not data then return nil, err end
    local sr = firstRow(data.series)
    if not sr then return nil, "That series was not found on Hardcover." end
    return seriesBooksFromRow(sr)
end

local function intIds(ids)
    local out = {}
    for i, id in ipairs(ids) do out[i] = tonumber(id) or id end
    return out
end

--- Books of several lists in one request: {[id] = books}. Lists Hardcover
-- did not return are left out.
function M:getListBooksMany(ids)
    local data, err, wait = self:query(LISTS_BOOKS_QUERY, { ids = intIds(ids) })
    if not data then return nil, err, wait end
    local out = {}
    for _, l in ipairs(isTable(data.lists) and data.lists or {}) do
        if isTable(l) and l.id then out[tonumber(l.id) or l.id] = collectBooks(l.list_books, "book") end
    end
    return out
end

--- Books of several series in one request: {[id] = books}.
function M:getSeriesBooksMany(ids)
    local data, err, wait = self:query(SERIES_MANY_QUERY, { ids = intIds(ids) })
    if not data then return nil, err, wait end
    local out = {}
    for _, sr in ipairs(isTable(data.series) and data.series or {}) do
        if isTable(sr) and sr.id and isString(sr.name) then out[tonumber(sr.id) or sr.id] = seriesBooksFromRow(sr) end
    end
    return out
end

--- One book (for a preview), as normalizeBook gives it.
function M:getBook(id)
    local data, err, wait = self:query(BOOK_QUERY, { id = tonumber(id) or id })
    if not data then return nil, err, wait end
    local row = isTable(data.books) and data.books[1]
    local b = M.normalizeBook(row)
    if not b then return nil, "That book was not found on Hardcover." end
    return b
end

--- Genre names from a book's cached_tags (most used first), at most max.
function M.genres(cached_tags, max, decode)
    local t = cached_tags
    if isString(t) and decode then
        local ok, d = pcall(decode, t)
        t = ok and d or nil
    end
    local out = {}
    if not isTable(t) then return out end
    local list = t.Genre or t.genre or t.Genres
    for _, g in ipairs(isTable(list) and list or {}) do
        local name = isTable(g) and (g.tag or g.name) or g
        if isString(name) and name ~= "" then out[#out + 1] = name end
        if #out >= (max or 5) then break end
    end
    return out
end

--- Genres of several books: {[id] = {"Fantasy", ...}}.
function M:getBookGenres(ids, max)
    local data, err, wait = self:query(BOOK_TAGS_QUERY, { ids = intIds(ids) })
    if not data then return nil, err, wait end
    local out = {}
    for _, b in ipairs(isTable(data.books) and data.books or {}) do
        if isTable(b) and b.id then out[tonumber(b.id) or b.id] = M.genres(b.cached_tags, max, self.json and self.json.decode) end
    end
    return out
end

--- Active reading goals: array of {id, goal, metric, progress, start_date,
-- end_date, description}.
function M:getGoals()
    local data, err, wait = self:query(GOALS_QUERY)
    if not data then return nil, err, wait end
    local me = firstRow(data.me)
    if not me then return nil, "Hardcover returned no user for this API key." end
    local out = {}
    for _, g in ipairs(isTable(me.goals) and me.goals or {}) do
        if isTable(g) and tonumber(g.goal) then
            out[#out + 1] = {
                id = tonumber(g.id), goal = tonumber(g.goal), progress = tonumber(g.progress) or 0,
                metric = isString(g.metric) and g.metric or "book",
                start_date = isString(g.start_date) and g.start_date or nil,
                end_date = isString(g.end_date) and g.end_date or nil,
                description = isString(g.description) and g.description or nil,
            }
        end
    end
    return out
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

--- Edit distance between two words, giving up (returning max + 1) as soon
-- as it is clearly larger than max.
local function distance(a, b, max)
    local la, lb = #a, #b
    if math.abs(la - lb) > max then return max + 1 end
    local prev = {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        local cur, best = { [0] = i }, i
        local ca = a:byte(i)
        for j = 1, lb do
            local cost = (ca == b:byte(j)) and 0 or 1
            local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            cur[j] = v
            if v < best then best = v end
        end
        if best > max then return max + 1 end
        prev = cur
    end
    return prev[lb]
end
M.distance = distance

--- Is word w in set, allowing for small differences: plurals ("stone" /
-- "stones"), possessives already stripped, and typos or spelling variants
-- (one wrong letter in words of 6+ letters, two in words of 10+).
local function has(set, w)
    if set[w] then return true end
    if set[w .. "s"] or set[w .. "es"] then return true end
    if #w > 3 and w:sub(-1) == "s" and set[w:sub(1, -2)] then return true end
    if #w < 6 or w:match("^%d+$") then return false end
    local max = #w >= 10 and 2 or 1
    for x in pairs(set) do
        if #x >= 5 and not x:match("^%d+$") and distance(w, x, max) <= max then return true end
    end
    return false
end
M.hasWord = has

--- All words of list in set; long titles (5+ words) may miss one word,
-- e.g. a dropped "Volume" or a word the uploader left out.
local function allIn(list, set)
    if #list == 0 then return false end
    local allowed = #list >= 5 and 1 or 0
    local missing = 0
    for _, w in ipairs(list) do
        if not has(set, w) then
            missing = missing + 1
            -- Stop at the first word too many: most files are not this book.
            if missing > allowed then return false end
        end
    end
    return true
end

local function surname(author)
    -- "Sanderson, Brandon"
    local before = tostring(author or ""):match("^([^,]+),")
    if before then author = before end
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
-- What matching needs from a book, worked out once per book rather than for
-- every file it is compared with (lists × files adds up on e-readers).
local compiled = setmetatable({}, { __mode = "k" })

local function compile(book)
    local c = compiled[book]
    local title = book.title or ""
    if c and c.title == title and c.author == book.author then return c end
    local candidates = { words(title) }
    local main, sub = title:match("^(.-)%s*:%s*(.+)$")
    if main then
        local mw, sw = words(main), words(sub)
        if #mw >= 2 then candidates[#candidates + 1] = mw end
        if #sw >= 2 then candidates[#candidates + 1] = sw end
    end
    local paren = title:gsub("%s*%b()", "")
    if paren ~= title then candidates[#candidates + 1] = words(paren) end
    c = {
        title = title,
        author = book.author,
        candidates = candidates,
        sname = book.author and surname(book.author),
    }
    compiled[book] = c
    return c
end

function M.matches(book, file)
    local set = file.set
    local c = compile(book)
    local sname = c.sname
    for _, cand in ipairs(c.candidates) do
        if allIn(cand, set) then
            if #cand >= 3 then return true end
            if not sname or has(set, sname) then return true end
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
-- match. Higher is better; extra words (other books, omnibus editions) count
-- against it.
-- The title must match and, when Hardcover knows the author, the surname of
-- one of the book's authors must be in the result too.
function M.resultScore(book, entry)
    local name = entry.title:gsub("%.[Zz][Ii][Pp]$", ""):gsub("%.[%w]+$", "")
    local file = { set = wordSet(name) }
    if not M.matches(book, file) then return nil end
    local names = {}
    for a in tostring(book.authors or ""):gmatch("[^,]+") do names[#names + 1] = a end
    if #names == 0 and book.author then names[1] = book.author end
    if #names > 0 then
        local found = false
        for _, a in ipairs(names) do
            local sname = surname(a)
            if sname and has(file.set, sname) then found = true break end
        end
        if not found then return nil end
    end
    local score = 10
    -- Exact words beat near misses, and every title word found counts.
    for _, w in ipairs(words(book.title or "")) do
        if file.set[w] then score = score + 0.2
        elseif not has(file.set, w) then score = score - 3 end
    end
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
