--[[--
IRC protocol helpers: line parsing, CTCP and DCC SEND offers.
Pure functions, no I/O.
]]

local M = {}

--- Parse a raw IRC line into {prefix=, nick=, command=, params={...}}.
-- The trailing parameter (after " :") is the last entry of params.
function M.parseLine(line)
    line = line:gsub("[\r\n]+$", "")
    if line == "" then return nil end
    local msg = { params = {} }
    local rest = line
    if rest:sub(1, 1) == "@" then -- IRCv3 message tags, ignored
        rest = rest:match("^@%S*%s+(.*)$") or ""
    end
    if rest:sub(1, 1) == ":" then
        msg.prefix, rest = rest:match("^:(%S+)%s*(.*)$")
        msg.nick = msg.prefix and msg.prefix:match("^([^!@]+)")
    end
    msg.command, rest = rest:match("^(%S+)%s*(.*)$")
    if not msg.command then return nil end
    msg.command = msg.command:upper()
    while rest and rest ~= "" do
        if rest:sub(1, 1) == ":" then
            table.insert(msg.params, rest:sub(2))
            break
        end
        local p, r = rest:match("^(%S+)%s*(.*)$")
        table.insert(msg.params, p)
        rest = r
    end
    return msg
end

--- If text is a CTCP message, return command (upper case) and argument string.
function M.parseCtcp(text)
    if not text or text:sub(1, 1) ~= "\1" then return nil end
    local body = text:gsub("^\1", ""):gsub("\1$", "")
    local cmd, args = body:match("^(%S+)%s*(.*)$")
    if not cmd then return nil end
    return cmd:upper(), args
end

--- Convert the address in a DCC offer to something socket.connect accepts.
function M.dccHost(addr)
    if addr:match("^%d+$") then
        local n = tonumber(addr)
        if not n or n <= 0 or n > 4294967295 then return nil end
        local a = math.floor(n / 16777216) % 256
        local b = math.floor(n / 65536) % 256
        local c = math.floor(n / 256) % 256
        local d = n % 256
        return string.format("%d.%d.%d.%d", a, b, c, d)
    end
    if addr:match("^[%d%.]+$") or addr:match(":") then
        return addr
    end
    return nil
end

--- Parse the argument string of a CTCP "DCC" message.
-- Returns {filename=, host=, port=, size=, passive=, token=} or nil, err.
function M.parseDccSend(args)
    local kind, rest = args:match("^(%S+)%s+(.*)$")
    if not kind or kind:upper() ~= "SEND" then return nil, "not a DCC SEND" end
    rest = rest:gsub("%s+$", "")
    local filename, addr, port, size, token
    if rest:sub(1, 1) == '"' then
        local tail
        filename, tail = rest:match('^"(.-)"%s+(.*)$')
        if not filename then return nil, "malformed DCC SEND" end
        addr, port, size, token = tail:match("^(%S+)%s+(%d+)%s+(%d+)%s*(%d*)$")
    else
        local f, a, p, s, t = rest:match("^(.-)%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)$")
        if f and p == "0" then
            filename, addr, port, size, token = f, a, p, s, t
        else
            filename, addr, port, size = rest:match("^(.-)%s+(%S+)%s+(%d+)%s+(%d+)$")
        end
    end
    if not filename or not addr then return nil, "malformed DCC SEND" end
    local offer = {
        filename = filename,
        addr = addr,
        port = tonumber(port),
        size = tonumber(size) or 0,
        token = token ~= "" and token or nil,
    }
    offer.passive = offer.port == 0
    offer.host = M.dccHost(addr)
    return offer
end

--- Make a file name from a remote peer safe to use in a local directory.
function M.safeFilename(name)
    name = tostring(name or "")
    name = name:gsub("^.*[/\\]", "")        -- drop any path component
    name = name:gsub("[%c\"<>|:%*%?]", "_") -- characters invalid on FAT/Windows
    name = name:gsub("^[%.%s]+", "")        -- no hidden files or "..", no leading space
    name = name:gsub("[%.%s]+$", "")
    if #name > 200 then
        local ext = name:match("(%.[%w]+)$") or ""
        name = name:sub(1, 200 - #ext) .. ext
    end
    if name == "" then name = "download" end
    return name
end

return M
