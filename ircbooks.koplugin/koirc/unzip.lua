--[[--
Minimal pure-Lua ZIP reader with a raw DEFLATE decoder.

IRC search bots send their results as a .zip holding one .txt file, and some
books arrive zipped as well. KOReader builds differ in which archive helpers
they ship, so this module has no dependency beyond LuaJIT's `bit` library.
]]

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local M = {}

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT  = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                8193, 12289, 16385, 24577 }
local DEXT  = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CLORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- Build a canonical Huffman table from code lengths (0-based symbol array).
local function build(lengths, n)
    local count = {}
    for i = 0, 15 do count[i] = 0 end
    for s = 0, n - 1 do
        local l = lengths[s] or 0
        count[l] = count[l] + 1
    end
    local offs = { [1] = 0 }
    for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
    local symbol = {}
    for s = 0, n - 1 do
        local l = lengths[s] or 0
        if l ~= 0 then
            symbol[offs[l]] = s
            offs[l] = offs[l] + 1
        end
    end
    return { count = count, symbol = symbol }
end

local fixed_lit, fixed_dist
local function fixed_tables()
    if not fixed_lit then
        local l = {}
        for s = 0, 143 do l[s] = 8 end
        for s = 144, 255 do l[s] = 9 end
        for s = 256, 279 do l[s] = 7 end
        for s = 280, 287 do l[s] = 8 end
        fixed_lit = build(l, 288)
        local d = {}
        for s = 0, 29 do d[s] = 5 end
        fixed_dist = build(d, 30)
    end
    return fixed_lit, fixed_dist
end

--- Decode a raw DEFLATE stream (no zlib/gzip header). Returns a string.
function M.inflate(data, start_pos)
    local pos = start_pos or 1
    local bitbuf, bitcnt = 0, 0
    local out, outn = {}, 0

    local function getbits(n)
        while bitcnt < n do
            local b = data:byte(pos)
            if not b then error("inflate: unexpected end of data") end
            pos = pos + 1
            bitbuf = bor(bitbuf, lshift(b, bitcnt))
            bitcnt = bitcnt + 8
        end
        local v = band(bitbuf, lshift(1, n) - 1)
        bitbuf = rshift(bitbuf, n)
        bitcnt = bitcnt - n
        return v
    end

    local function decode(h)
        local code, first, index = 0, 0, 0
        local count, symbol = h.count, h.symbol
        for len = 1, 15 do
            code = code + getbits(1)
            local c = count[len]
            if code - c < first then
                return symbol[index + (code - first)]
            end
            index = index + c
            first = (first + c) * 2
            code = code * 2
        end
        error("inflate: invalid Huffman code")
    end

    local function codes(lit, dist)
        while true do
            local sym = decode(lit)
            if sym < 256 then
                outn = outn + 1
                out[outn] = sym
            elseif sym == 256 then
                return
            else
                sym = sym - 257
                if sym >= 29 then error("inflate: bad length symbol") end
                local len = LBASE[sym + 1] + getbits(LEXT[sym + 1])
                local ds = decode(dist)
                if ds >= 30 then error("inflate: bad distance symbol") end
                local d = DBASE[ds + 1] + getbits(DEXT[ds + 1])
                if d > outn then error("inflate: distance too far back") end
                local from = outn - d
                for i = 1, len do
                    out[outn + i] = out[from + i]
                end
                outn = outn + len
            end
        end
    end

    local last
    repeat
        last = getbits(1)
        local btype = getbits(2)
        if btype == 0 then
            bitbuf, bitcnt = 0, 0 -- skip to byte boundary
            local b1, b2, b3, b4 = data:byte(pos, pos + 3)
            if not b4 then error("inflate: unexpected end of data") end
            local len = b1 + b2 * 256
            local nlen = b3 + b4 * 256
            if len ~= 65535 - nlen then error("inflate: stored block length mismatch") end
            pos = pos + 4
            if pos + len - 1 > #data then error("inflate: unexpected end of data") end
            for i = 0, len - 1 do
                out[outn + 1 + i] = data:byte(pos + i)
            end
            outn = outn + len
            pos = pos + len
        elseif btype == 1 then
            codes(fixed_tables())
        elseif btype == 2 then
            local nlen = getbits(5) + 257
            local ndist = getbits(5) + 1
            local ncode = getbits(4) + 4
            local lengths = {}
            for i = 1, 19 do lengths[CLORDER[i]] = 0 end
            for i = 1, ncode do lengths[CLORDER[i]] = getbits(3) end
            local lencode = build(lengths, 19)
            local all = {}
            local idx = 0
            while idx < nlen + ndist do
                local sym = decode(lencode)
                if sym < 16 then
                    all[idx] = sym
                    idx = idx + 1
                else
                    local rep, val = 0, 0
                    if sym == 16 then
                        if idx == 0 then error("inflate: repeat with no previous length") end
                        val = all[idx - 1]
                        rep = 3 + getbits(2)
                    elseif sym == 17 then
                        rep = 3 + getbits(3)
                    else
                        rep = 11 + getbits(7)
                    end
                    if idx + rep > nlen + ndist then error("inflate: too many lengths") end
                    for _ = 1, rep do
                        all[idx] = val
                        idx = idx + 1
                    end
                end
            end
            local litl, distl = {}, {}
            for i = 0, nlen - 1 do litl[i] = all[i] end
            for i = 0, ndist - 1 do distl[i] = all[nlen + i] end
            codes(build(litl, nlen), build(distl, ndist))
        else
            error("inflate: invalid block type")
        end
    until last == 1

    local parts = {}
    local CH = 4096
    for i = 1, outn, CH do
        parts[#parts + 1] = string.char(unpack(out, i, math.min(i + CH - 1, outn)))
    end
    return table.concat(parts), pos
end

local function u16(s, p)
    local a, b = s:byte(p, p + 1)
    return a + b * 256
end

local function u32(s, p)
    local a, b, c, d = s:byte(p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

--- Returns true if the string starts with a ZIP local file header.
function M.isZip(data)
    return data:sub(1, 4) == "PK\3\4"
end

--- List entries of a ZIP archive held in a string.
-- Returns an array of {name=, method=, csize=, usize=, offset=} or nil, err.
function M.list(data)
    local eocd
    local min = math.max(1, #data - 65557)
    for p = #data - 21, min, -1 do
        if data:byte(p) == 0x50 and data:sub(p, p + 3) == "PK\5\6" then
            eocd = p
            break
        end
    end
    if not eocd then return nil, "not a zip archive" end
    local n = u16(data, eocd + 10)
    local cd = u32(data, eocd + 16) + 1
    local entries = {}
    local p = cd
    for _ = 1, n do
        if data:sub(p, p + 3) ~= "PK\1\2" then return nil, "corrupt zip directory" end
        local method = u16(data, p + 10)
        local csize = u32(data, p + 20)
        local usize = u32(data, p + 24)
        local nlen = u16(data, p + 28)
        local elen = u16(data, p + 30)
        local clen = u16(data, p + 32)
        local off = u32(data, p + 42) + 1
        local name = data:sub(p + 46, p + 45 + nlen)
        entries[#entries + 1] = { name = name, method = method, csize = csize, usize = usize, offset = off }
        p = p + 46 + nlen + elen + clen
    end
    return entries
end

--- Extract one entry (from M.list) of the archive. Returns content or nil, err.
function M.extract(data, entry)
    local p = entry.offset
    if data:sub(p, p + 3) ~= "PK\3\4" then return nil, "corrupt local header" end
    local start = p + 30 + u16(data, p + 26) + u16(data, p + 28)
    if entry.method == 0 then
        return data:sub(start, start + entry.csize - 1)
    elseif entry.method == 8 then
        local ok, res = pcall(M.inflate, data, start)
        if not ok then return nil, res end
        return res
    end
    return nil, "unsupported compression method " .. tostring(entry.method)
end

--- Convenience: extract every file entry. Returns array of {name=, data=}.
function M.extractAll(data)
    local entries, err = M.list(data)
    if not entries then return nil, err end
    local files = {}
    for _, e in ipairs(entries) do
        if e.name:sub(-1) ~= "/" then
            local content, xerr = M.extract(data, e)
            if not content then return nil, xerr end
            files[#files + 1] = { name = e.name, data = content }
        end
    end
    return files
end

return M
