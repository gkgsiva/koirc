--[[--
Is a book's format good for reading on this device, and is there a better
copy?

KOReader opens EPUB, MOBI, AZW3, FB2, PDF, DjVu and CBZ itself, so books
in those formats never need converting to be read. Turning MOBI or AZW3
into EPUB (or the other way) needs Calibre, which does not run on an
e-reader. What the plugin does instead:
- files whose content is another format than their name says are renamed
  (koirc/quality.lua), so KOReader opens them;
- when the downloaded copy is not in the first preferred format and the
  search had the same book in a better one, it offers (or, in the
  background, takes) that copy instead;
- it warns about formats that read badly on an e-reader.

No KOReader dependencies, so it is tested in spec/run.lua.
]]

local results = require("koirc/results")

local M = {}

-- Why a format is poor on an e-reader.
M.POOR = {
    pdf = "PDF pages have a fixed size: text is small on an e-reader screen (reflow helps a little)",
    djvu = "DjVu is scanned pages: text can't be resized",
    txt = "plain text has no chapters, table of contents or formatting",
    rtf = "RTF opens, but chapters and formatting are often lost",
    doc = "Word documents open with little formatting",
    docx = "Word documents open with little formatting",
    htm = "a web page: no chapters, and pictures may be missing",
    html = "a web page: no chapters, and pictures may be missing",
    lit = "LIT is an old format that often doesn't open",
    pdb = "PDB is an old format that often doesn't open",
    rar = "an archive KOReader can't open",
    ["7z"] = "an archive KOReader can't open",
    cbr = "a RAR comic archive, which KOReader can't open",
}

--- Warning for a format, or nil when it reads well.
function M.warning(ext)
    return M.POOR[tostring(ext or ""):lower()]
end

--- The copy to get instead of entry: the same book (by ranked, the
-- results that match it, best first) in a format earlier in prefs, or nil.
-- It is not given when entry is already in the first preferred format.
function M.betterCopy(entry, ranked, prefs)
    if not entry or not prefs or #prefs == 0 then return nil end
    local have = results.formatRank(entry, prefs)
    if have <= 1 then return nil end
    for _i, e in ipairs(ranked or {}) do
        if e ~= entry and e.request ~= entry.request then
            local r = results.formatRank(e, prefs)
            if r < have and r <= #prefs then return e end
        end
    end
end

return M
