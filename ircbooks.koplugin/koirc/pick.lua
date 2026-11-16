--[[--
Choosing which IRC result to download: every result gets a score and the
reasons for it, so the plugin can show why it picked a file and let the user
pick another one.

What counts (higher is better):
- how well the title and author match the book (or the words searched for)
- the preferred formats, in order, and the formats the user keeps picking
- a size that makes sense: tiny files are often broken or samples, and a
  copy much smaller than the others is often abridged
- abridged, sample, excerpt or summary editions count against a result
- bot health: bots that send their files reliably and fast come first; bots
  not in the channel, or that just failed, come last
- books already on the device (checked for the best few only, to stay fast)

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local Hardcover = require("koirc/hardcover")
local results = require("koirc/results")

local M = {}

-- Book formats that are never this small when they hold a whole book.
M.MIN_BYTES = {
    epub = 20 * 1024, mobi = 20 * 1024, azw3 = 20 * 1024, azw = 20 * 1024, fb2 = 15 * 1024,
    pdf = 40 * 1024, djvu = 40 * 1024, cbz = 100 * 1024, cbr = 100 * 1024,
    txt = 4 * 1024, rtf = 8 * 1024, doc = 10 * 1024, docx = 10 * 1024, lit = 15 * 1024,
}
-- Text formats larger than this are unusual (scans, or several books).
M.HUGE_BYTES = 60 * 1048576
local TEXT_FORMATS = { epub = true, mobi = true, azw3 = true, azw = true, fb2 = true, txt = true, rtf = true, lit = true }

-- Words that mark a book that is not the full text.
M.PARTIAL_WORDS = {
    "abridged", "sample", "excerpt", "preview", "summary", "study guide", "sparknotes",
    "cliffsnotes", "cliff notes", "workbook", "teaser", "condensed", "analysis of",
}

-- Results checked against the books on the device (the best ones only).
M.OWNED_CHECKS = 5

local function words(s)
    local list = {}
    for w in Hardcover.normalize(s):gmatch("%S+") do list[#list + 1] = w end
    return list
end

local function set(list)
    local out = {}
    for _i, w in ipairs(list) do out[w] = true end
    return out
end

local function nameOf(entry)
    return (entry.title or ""):gsub("%.[Zz][Ii][Pp]$", ""):gsub("%.[%w]+$", "")
end

-- The normalized name, kept on the entry: results are ranked again on
-- every filter change, and normalizing thousands of names adds up.
local function normName(entry)
    local n = entry._pick_norm
    if not n then
        n = Hardcover.normalize(nameOf(entry))
        entry._pick_norm = n
    end
    return n
end

--- Sizes as text, short: "12 KB", "1.4 MB".
function M.sizeText(n)
    if not n then return "?" end
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%d KB", math.max(1, math.floor(n / 1024 + 0.5)))
end

--- Which of the partial-edition words are in the result but not in the
-- book's own title (a book called "The Sample" is fine). Returns the word
-- or nil.
function M.partialWord(entry, book_title)
    local hay = " " .. normName(entry) .. " "
    local own = " " .. Hardcover.normalize(book_title or "") .. " "
    for _i, w in ipairs(M.PARTIAL_WORDS) do
        local pat = " " .. w .. " "
        if hay:find(pat, 1, true) and not own:find(pat, 1, true) then
            -- "unabridged" is a different word, so it never gets here.
            return w
        end
    end
end

--- Share of the searched words found in the result (0..1), fuzzy.
local function coverage(query_words, entry)
    if #query_words == 0 then return 1 end
    local s = entry._pick_set
    if not s then
        s = set(words(normName(entry) .. " " .. (entry.bot or "")))
        entry._pick_set = s
    end
    local found = 0
    for _i, w in ipairs(query_words) do
        if Hardcover.hasWord(s, w) then found = found + 1 end
    end
    return found / #query_words
end

local ORDINALS = { "1st", "2nd", "3rd" }
local function ordinal(n) return ORDINALS[n] or (tostring(n) .. "th") end

--- Score every result. opts:
--   book       the Hardcover book (or a guess) being looked for, or nil
--   query      the words searched for, used when there is no book
--   prefs      preferred formats, best first ({ "epub", "mobi" })
--   health     koirc/bothealth object, or nil
--   learn      true: the formats and bots the user picks count
--   tracker    koirc/retry tracker (bots that just failed), or nil
--   online(bot)  true/false/nil
--   blocked    set of lowercase bot names never to use
--   owned(entry) true (or a path) when the book is already on the device
--   drop_offline  leave out bots known not to be in the channel
--   tried      set of requests already tried (left out)
-- Returns ranked (array of entries, best first) and info (entry ->
-- {score, why = {...}, warn = {...}, owned = path}).
function M.rank(list, opts)
    opts = opts or {}
    local prefs = opts.prefs or {}
    local book = opts.book
    local qwords
    if not book then
        qwords = {}
        for _i, w in ipairs(words(opts.query or "")) do
            if #w > 1 then qwords[#qwords + 1] = w end
        end
    end
    local blocked = opts.blocked or {}
    -- The usual size of a copy, to spot ones much smaller than the rest.
    local sizes = {}
    local scored = {}
    for i, e in ipairs(list or {}) do
        local bot = tostring(e.bot or ""):lower()
        local skip = blocked[bot] or (opts.tried and opts.tried[e.request])
        local online = opts.online and opts.online(e.bot)
        if not skip and opts.drop_offline and online == false then skip = true end
        local match
        if not skip then
            if book then
                match = Hardcover.resultScore(book, e)
            else
                match = coverage(qwords, e) * 10
            end
        end
        if match then
            local s = { e = e, i = i, match = match, online = online, why = {}, warn = {} }
            scored[#scored + 1] = s
            local n = results.sizeBytes(e.size)
            if n then sizes[#sizes + 1] = n end
        end
    end
    table.sort(sizes)
    local median = #sizes >= 3 and sizes[math.floor((#sizes + 1) / 2)] or nil

    local health = opts.health
    for _i, s in ipairs(scored) do
        local e = s.e
        local why, warn = s.why, s.warn
        -- The match counts most: a better title match beats a better format.
        local score = s.match * 1.5
        if book then
            if s.match >= 10 then why[#why + 1] = "title and author match"
            elseif s.match >= 8 then why[#why + 1] = "title matches, some extra words"
            else warn[#warn + 1] = "title only partly matches" end
        elseif #qwords > 0 then
            if s.match >= 10 then why[#why + 1] = "has every word searched for"
            elseif s.match >= 6 then why[#why + 1] = "has most words searched for"
            else warn[#warn + 1] = "few of the words searched for" end
        end
        -- Format
        local ext = results.bookExt(e)
        local r = results.formatRank(e, prefs)
        if r >= 1000 then
            score = score - 20
            warn[#warn + 1] = "archive KOReader can't open"
        elseif r <= #prefs then
            score = score + math.max(0, 3 - (r - 1) * 0.75)
            why[#why + 1] = string.format("%s: your %s format", (ext or "?"):upper(), ordinal(r))
        else
            why[#why + 1] = string.format("%s: not one of your formats", (ext or "?"):upper())
        end
        if opts.learn and health and ext then
            local share = health:formatShare(ext)
            if share > 0 then score = score + share * 1.5 end
        end
        -- Size
        local n = results.sizeBytes(e.size)
        local min = ext and M.MIN_BYTES[ext]
        if n and min and n < min then
            score = score - 4
            warn[#warn + 1] = "only " .. M.sizeText(n) .. ": may be broken or a sample"
        elseif n and median and median >= 200 * 1024 and n < median * 0.2 and TEXT_FORMATS[ext or ""] then
            score = score - 2
            warn[#warn + 1] = "much smaller than other copies (" .. M.sizeText(n) .. ")"
        elseif n and TEXT_FORMATS[ext or ""] and n > M.HUGE_BYTES then
            score = score - 1.5
            warn[#warn + 1] = "very large for a book (" .. M.sizeText(n) .. ")"
        end
        -- Not the full text
        local partial = M.partialWord(e, book and book.title)
        if partial then
            score = score - 5
            warn[#warn + 1] = "looks like a " .. partial .. ", not the full book"
        end
        if (" " .. normName(e) .. " "):find(" retail ", 1, true) then
            score = score + 0.5
            why[#why + 1] = "retail copy"
        end
        -- Bot
        if s.online == false then
            score = score - 6
            warn[#warn + 1] = "bot is not in the channel"
        end
        local bad = opts.tracker and opts.tracker:isBad(e.bot)
        if bad then
            score = score - 3
            warn[#warn + 1] = "bot failed a moment ago"
        end
        if health then
            local hs = health:score(e.bot)
            score = score + (hs - 50) / 20
            local b = health:bot(e.bot)
            if b and b.ok + b.fail >= 2 then
                local pct = math.floor(health:reliability(e.bot) * 100 + 0.5)
                if pct >= 70 then why[#why + 1] = string.format("bot sent %d%% of books", pct)
                else warn[#warn + 1] = string.format("bot sent only %d%% of books", pct) end
            end
            if opts.learn then
                local picks = health.data.picks[tostring(e.bot or ""):lower()] or 0
                score = score + math.min(picks, 5) * 0.1
            end
        end
        s.score = score
    end

    local function sortAll()
        table.sort(scored, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.i < b.i
        end)
    end
    sortAll()
    -- Books already on the device: only the best few, since looking costs.
    if opts.owned then
        local changed = false
        for k = 1, math.min(#scored, M.OWNED_CHECKS) do
            local s = scored[k]
            local have = opts.owned(s.e)
            if have then
                s.owned = type(have) == "string" and have or true
                s.score = s.score - 8
                s.warn[#s.warn + 1] = "already on the device"
                changed = true
            end
        end
        if changed then sortAll() end
    end
    local ranked, info = {}, {}
    for k, s in ipairs(scored) do
        ranked[k] = s.e
        info[s.e] = { score = s.score, why = s.why, warn = s.warn, owned = s.owned, match = s.match }
    end
    return ranked, info
end

--- One line: "EPUB: your 1st format · bot sent 95% of books".
function M.summary(inf, max)
    if not inf then return "" end
    local parts = {}
    for _i, w in ipairs(inf.warn or {}) do parts[#parts + 1] = "⚠ " .. w end
    for _i, w in ipairs(inf.why or {}) do parts[#parts + 1] = w end
    max = max or #parts
    local out = {}
    for i = 1, math.min(max, #parts) do out[i] = parts[i] end
    return table.concat(out, " · ")
end

--- Several lines, for a "why this file" dialog.
function M.explain(inf)
    if not inf then return "" end
    local lines = {}
    for _i, w in ipairs(inf.why or {}) do lines[#lines + 1] = "✓ " .. w end
    for _i, w in ipairs(inf.warn or {}) do lines[#lines + 1] = "⚠ " .. w end
    return table.concat(lines, "\n")
end

--- True when a person should look before this pick is downloaded: a
-- warning on it, or a weak title match.
function M.unsure(inf)
    if not inf then return true end
    if #(inf.warn or {}) > 0 then return true end
    return (inf.match or 0) < 9.5
end

return M
