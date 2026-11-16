--[[--
Checking a downloaded file before it counts as a book: empty or tiny files,
web pages saved instead of the book, cut-off zips (EPUB, CBZ) and PDFs, and
files whose content is another format than their name says.

A file with the wrong extension but a good book inside (a MOBI called
.epub) is not thrown away: check() says which extension it should have.

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local M = {}

-- Files smaller than this are never a whole book (bytes).
M.MIN_BYTES = 2048
M.MIN_TEXT_BYTES = 512
-- A file this much smaller than the size the search listed is cut off or
-- another file.
M.MIN_SHARE_OF_LISTED = 0.4

-- What content each extension should have.
local EXPECT = {
    epub = "zip", cbz = "zip", docx = "zip", kepub = "zip",
    mobi = "mobi", azw = "mobi", azw3 = "mobi", prc = "mobi", pdb = "mobi",
    pdf = "pdf", djvu = "djvu", djv = "djvu",
    fb2 = "fb2",
    rtf = "rtf", doc = "doc", lit = "lit",
    cbr = "rar", rar = "rar", ["7z"] = "7z", zip = "zip",
    htm = "html", html = "html", txt = "text",
}

-- The extension to give a file by its content, when the name is wrong.
local EXT_FOR = { mobi = "mobi", pdf = "pdf", djvu = "djvu", fb2 = "fb2", rtf = "rtf", epub = "epub", rar = "rar", ["7z"] = "7z" }

local NAMES = {
    zip = "zip", mobi = "MOBI/AZW3", pdf = "PDF", djvu = "DjVu", fb2 = "FB2", rtf = "RTF",
    doc = "Word", lit = "LIT", rar = "RAR", ["7z"] = "7z", html = "web page", text = "text",
    xml = "XML", epub = "EPUB",
}

--- What a file is, from its first bytes: "epub", "zip", "mobi", "pdf",
-- "djvu", "fb2", "xml", "rtf", "doc", "lit", "rar", "7z", "html", "text"
-- or "unknown".
function M.detect(head)
    head = head or ""
    if head == "" then return "empty" end
    if head:sub(1, 4) == "PK\3\4" then
        -- An EPUB starts with an uncompressed "mimetype" member.
        if head:sub(31, 38) == "mimetype" and head:find("application/epub+zip", 39, true) then return "epub" end
        return "zip"
    end
    if head:sub(61, 68) == "BOOKMOBI" or head:sub(61, 68) == "TEXtREAd" then return "mobi" end
    if head:sub(1, 1024):find("%PDF-", 1, true) then return "pdf" end
    if head:sub(1, 8) == "AT&TFORM" then return "djvu" end
    if head:sub(1, 4) == "Rar!" then return "rar" end
    if head:sub(1, 6) == "7z\188\175\39\28" then return "7z" end
    if head:sub(1, 5) == "{\\rtf" then return "rtf" end
    if head:sub(1, 4) == "\208\207\17\224" then return "doc" end
    if head:sub(1, 8) == "ITOLITLS" then return "lit" end
    local start = head:gsub("^\239\187\191", ""):gsub("^%s+", ""):sub(1, 1024):lower()
    if start:sub(1, 5) == "<?xml" or start:sub(1, 12) == "<fictionbook" then
        if start:find("<fictionbook", 1, true) then return "fb2" end
        if start:find("<html", 1, true) then return "html" end
        return "xml"
    end
    if start:find("^<!doctype html") or start:find("^<html") or start:find("<head>", 1, true) or start:find("<body", 1, true) then
        return "html"
    end
    -- Mostly printable: plain text.
    local sample = head:sub(1, 2048)
    local bad = 0
    for i = 1, #sample do
        local b = sample:byte(i)
        if b < 9 or (b > 13 and b < 32) then bad = bad + 1 end
    end
    if bad <= #sample * 0.02 then return "text" end
    return "unknown"
end

local function kindMatches(expected, kind)
    if expected == kind then return true end
    if expected == "zip" and kind == "epub" then return true end
    if expected == "fb2" and kind == "xml" then return true end
    if expected == "html" and kind == "xml" then return true end
    -- Text files may hold anything printable, including HTML.
    if expected == "text" and (kind == "html" or kind == "xml" or kind == "fb2" or kind == "rtf") then return true end
    return false
end

--- Check a downloaded file. file: { size = bytes, head = first 4 KB,
-- tail = last 64 KB (or the whole file when small), ext = "epub",
-- listed = size the search listed (bytes, or nil) }.
-- Returns { ok = bool, reason = text (when not ok), fix_ext = ext (when the
-- file is good but named wrongly), kind = detected kind }.
function M.check(file)
    local ext = tostring(file.ext or ""):lower()
    local size = tonumber(file.size) or 0
    local kind = M.detect(file.head)
    local res = { ok = true, kind = kind }
    local function fail(reason)
        res.ok = false
        res.reason = reason
        return res
    end
    if size <= 0 or kind == "empty" then return fail("the file is empty") end
    local min = ext == "txt" and M.MIN_TEXT_BYTES or M.MIN_BYTES
    if size < min then return fail(string.format("the file is only %d bytes", size)) end
    local listed = tonumber(file.listed)
    if listed and listed > 100 * 1024 and size < listed * M.MIN_SHARE_OF_LISTED then
        return fail(string.format("got %d KB of the %d KB listed", math.floor(size / 1024), math.floor(listed / 1024)))
    end
    if kind == "html" and ext ~= "html" and ext ~= "htm" and ext ~= "txt" then
        return fail("a web page (an error message?) was sent, not the book")
    end
    local expected = EXPECT[ext]
    if expected and not kindMatches(expected, kind) then
        local new_ext = EXT_FOR[kind]
        if new_ext then
            -- A good book with the wrong name.
            res.fix_ext = new_ext
        elseif kind == "zip" and expected ~= "zip" then
            return fail(string.format("a zip file was sent, not a %s file", ext:upper()))
        else
            if ext == "txt" and kind == "unknown" then return res end -- UTF-16 text, say
            return fail(string.format("this is not a real %s file (looks like %s)", ext:upper(), NAMES[kind] or "unknown data"))
        end
    end
    local real = res.fix_ext and EXPECT[res.fix_ext] or expected
    local tail = file.tail or ""
    if (real == "zip" or kind == "zip" or kind == "epub") and tail ~= "" then
        -- A zip ends with its directory; a cut-off file has none.
        if not tail:find("PK\5\6", 1, true) then return fail("the file is cut off (damaged zip)") end
    end
    if (real == "pdf" or kind == "pdf") and tail ~= "" then
        if not tail:sub(-8192):find("%%EOF", 1, true) then return fail("the file is cut off (damaged PDF)") end
    end
    return res
end

--- Read what check() needs from a file on disk. io_open defaults to io.open.
-- Returns the table for check(), or nil when it can't be read.
function M.readFile(path, listed, io_open)
    local f = (io_open or io.open)(path, "rb")
    if not f then return nil end
    local size = f:seek("end") or 0
    f:seek("set", 0)
    local head = f:read(4096) or ""
    local tail = ""
    if size > 0 then
        local n = math.min(size, 65536)
        f:seek("set", size - n)
        tail = f:read(n) or ""
    end
    f:close()
    local name = path:match("([^/]+)$") or path
    return { size = size, head = head, tail = tail, ext = name:match("%.([%w]+)$"), listed = listed }
end

--- Short text for messages.
function M.describe(res)
    return res and res.reason or "the file is damaged"
end

return M
