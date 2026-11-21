local M = {}

function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Make a string safe as one file or folder name (FAT/Kindle friendly).
function M.safe_name(s, fallback)
    s = tostring(s or ""):gsub("[%c/\\:*?\"<>|]", "_")
    s = M.trim(s):gsub("^%.+", ""):gsub("[%. ]+$", "")
    if #s > 120 then
        local ext = s:match("(%.[%w]+)$")
        if ext and #ext <= 8 then s = s:sub(1, 120 - #ext) .. ext else s = s:sub(1, 120) end
        -- do not cut in the middle of a UTF-8 sequence
        while #s > 0 and s:byte(#s) >= 0x80 and s:byte(#s) < 0xC0 do s = s:sub(1, -2) end
    end
    if s == "" then return fallback or "_" end
    return s
end

function M.url_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- "https://host:8080/opds/" -> "https://host:8080" (what the catalog paths hang off).
function M.origin(url)
    return url:match("^(%a[%w+.-]*://[^/]+)") or url
end

--- User typed address -> base URL with no trailing slash or /opds.
function M.normalize_server(url)
    url = M.trim(url or "")
    if url == "" then return nil end
    if not url:match("^%a[%w+.-]*://") then url = "https://" .. url end
    url = url:gsub("/+$", ""):gsub("/opds$", ""):gsub("/+$", "")
    return url
end

--- Resolve an href found in a feed against the URL of the feed.
function M.resolve(base, href)
    if href:match("^%a[%w+.-]*://") then return href end
    if href:sub(1, 1) == "/" then return M.origin(base) .. href end
    local dir = base:gsub("[?#].*$", ""):gsub("[^/]*$", "")
    return dir .. href
end

function M.file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

function M.mkdirs(path)
    local ok, util = pcall(require, "util")
    if ok and util.makePath then return util.makePath(path) end
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
    return true
end

--- Free bytes on the file system holding dir, or nil if unknown.
function M.free_space(dir)
    local ok, kutil = pcall(require, "util")
    if ok and type(kutil) == "table" and kutil.diskUsage then
        local ok2, u = pcall(kutil.diskUsage, dir)
        if ok2 and type(u) == "table" and tonumber(u.available) then return tonumber(u.available) end
    end
    local h = io.popen("df -k '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    local line = out:match("\n([^\n]+)")  -- second line
    -- Filesystem 1K-blocks Used Available ...
    local avail = line and select(4, line:match("^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)"))
    return avail and tonumber(avail) * 1024 or nil
end

function M.copy_file(from, to)
    local a = io.open(from, "rb")
    if not a then return false end
    local b = io.open(to .. ".part", "wb")
    if not b then a:close() return false end
    while true do
        local d = a:read(65536)
        if not d then break end
        b:write(d)
    end
    a:close() b:close()
    os.remove(to)
    return os.rename(to .. ".part", to) and true or false
end

--- Minimal Lua-table serializer for the sync state file.
local function ser(v, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{"
        for k, x in pairs(v) do
            local kk = type(k) == "number" and string.format("%.17g", k) or string.format("%q", tostring(k))
            out[#out + 1] = "[" .. kk .. "]="
            ser(x, out)
            out[#out + 1] = ","
        end
        out[#out + 1] = "}"
    elseif t == "number" then
        out[#out + 1] = string.format("%.17g", v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    else
        out[#out + 1] = string.format("%q", tostring(v))
    end
end

function M.save_table(path, tbl)
    local out = { "return " }
    ser(tbl, out)
    local f = io.open(path .. ".tmp", "wb")
    if not f then return false end
    f:write(table.concat(out))
    f:close()
    os.remove(path)
    return os.rename(path .. ".tmp", path) and true or false
end

function M.load_table(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then return t end
end

return M
