--[[--
Download history records: what was downloaded, from which bot, where it was
saved. No KOReader dependencies (tested in spec/run.lua).

A record: {at, title, author, bot, request, size, ext, path, book_id,
book_title}
]]

local M = {}

M.MAX = 300

--- A record for a finished download. book: the Hardcover book or nil.
function M.make(path, book, entry, now)
    local name = (entry.title or ""):gsub("%.[%w]+$", "")
    local author, title = name:match("^(.-)%s+%-%s+(.+)$")
    return {
        at = now,
        title = (book and book.title) or title or name,
        author = (book and (book.author or book.authors)) or author,
        bot = entry.bot,
        request = entry.request,
        size = entry.size,
        ext = entry.ext,
        file_title = entry.title,
        path = path,
        book_id = book and book.id or nil,
    }
end

--- Add rec at the top. The same request downloaded again replaces the old
-- record. Keeps at most M.MAX records.
function M.add(list, rec)
    for i = #list, 1, -1 do
        if list[i].request == rec.request then table.remove(list, i) end
    end
    table.insert(list, 1, rec)
    while #list > M.MAX do table.remove(list) end
    return list
end

function M.remove(list, rec)
    for i = #list, 1, -1 do
        if list[i] == rec or (list[i].request == rec.request and list[i].at == rec.at) then table.remove(list, i) end
    end
end

--- Records whose title, author, bot or file name contain every word of text.
function M.search(list, text)
    if not text or not text:find("%S") then return list end
    local words = {}
    for w in text:lower():gmatch("%S+") do words[#words + 1] = w end
    local out = {}
    for _i, r in ipairs(list) do
        local hay = table.concat({ r.title or "", r.author or "", r.bot or "", r.file_title or "", r.ext or "" }, " "):lower()
        local ok = true
        for _k, w in ipairs(words) do
            if not hay:find(w, 1, true) then ok = false break end
        end
        if ok then out[#out + 1] = r end
    end
    return out
end

--- The IRC result entry to request the same file again.
function M.entry(r)
    return {
        bot = r.bot,
        request = r.request,
        title = r.file_title or (r.request or ""):gsub("^!%S+%s+", ""),
        size = r.size,
        ext = r.ext,
    }
end

--- The book, for finding other copies when the bot is gone.
function M.book(r)
    return { id = r.book_id, title = r.title, author = r.author, authors = r.author }
end

--- Text to search IRC for the book again.
function M.query(r)
    local q = ((r.author and r.author ~= "") and (r.author .. " ") or "") .. (r.title or "")
    q = q:gsub("[%[%]%(%){}:;,!%?\"“”]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return q
end

return M
