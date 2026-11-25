-- A small JSON decoder (objects, arrays, strings with escapes, numbers, true/false/null), for
-- the Library's API answers and GitHub's release info. No KOReader dependencies, so the
-- specs run it as is. null becomes nil (in arrays: M.null, so positions are kept).
local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local function utf8_char(c)
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 0x40), 0x80 + c % 0x40) end
    if c < 0x10000 then
        return string.char(0xE0 + math.floor(c / 0x1000), 0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
    end
    return string.char(0xF0 + math.floor(c / 0x40000), 0x80 + math.floor(c / 0x1000) % 0x40,
        0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local decode_value

local function skip(s, i)
    return s:find("[^ \t\r\n]", i) or #s + 1
end

local function decode_string(s, i)
    -- s:sub(i, i) == '"'
    local out, j = {}, i + 1
    while true do
        local a, b = s:find('["\\]', j)
        if not a then error("unterminated string") end
        out[#out + 1] = s:sub(j, a - 1)
        if s:sub(a, a) == '"' then return table.concat(out), a + 1 end
        local e = s:sub(a + 1, a + 1)
        if e == "u" then
            local c = tonumber(s:sub(a + 2, a + 5), 16)
            if not c then error("bad \\u escape") end
            local nxt = a + 6
            if c >= 0xD800 and c <= 0xDBFF and s:sub(nxt, nxt + 1) == "\\u" then
                local lo = tonumber(s:sub(nxt + 2, nxt + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    c = 0x10000 + (c - 0xD800) * 0x400 + (lo - 0xDC00)
                    nxt = nxt + 6
                end
            end
            out[#out + 1] = utf8_char(c)
            j = nxt
        else
            out[#out + 1] = ESC[e] or e
            j = a + 2
        end
    end
end

decode_value = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip(s, i)
            if s:sub(i, i) ~= '"' then error("object key expected at " .. i) end
            local k
            k, i = decode_string(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then error("':' expected at " .. i) end
            local v
            v, i = decode_value(s, i + 1)
            if v ~= M.null then obj[k] = v end
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then error("',' or '}' expected at " .. i) end
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v
            v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then error("',' or ']' expected at " .. i) end
            i = i + 1
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return M.null, i + 4
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num and num ~= "" and tonumber(num) then return tonumber(num), i + #num end
    error("unexpected character at " .. i)
end

--- Decode a JSON text. Returns the value, or nil, error.
function M.decode(s)
    if type(s) ~= "string" then return nil, "no text" end
    local ok, v = pcall(decode_value, s, 1)
    if not ok then return nil, tostring(v) end
    if v == M.null then return nil end
    return v
end

return M
