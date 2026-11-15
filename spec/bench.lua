-- Speed check for the Hardcover screens on a large synthetic library: loads
-- hardcoverui.lua and collections.lua with stand-ins for KOReader modules.
-- Usage: luajit spec/bench.lua ircbooks.koplugin [books] [files]
local plugin = arg[1]
local NBOOKS = tonumber(arg[2]) or 1500
local NFILES = tonumber(arg[3]) or 3000
package.path = plugin .. "/?.lua;" .. package.path
local SCRATCH = os.getenv("BENCH_DIR") or (os.getenv("TMPDIR") or "/tmp") .. "/ircbooks-bench"
os.execute("mkdir -p " .. SCRATCH)

local clock = os.clock
local function stub() return setmetatable({}, { __index = function() return function() end end, __call = function() end }) end
local stats = { stat = 0, flush = 0, flush_bytes = 0, bookinfo = 0, realpath = 0, scheduled = {} }

-- serializer close to KOReader's dump.lua (sorted keys)
local function dump(v, out, indent)
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) < type(b)
        end)
        out[#out + 1] = "{\n"
        for _, k in ipairs(keys) do
            out[#out + 1] = indent .. "    ["
            out[#out + 1] = type(k) == "string" and string.format("%q", k) or tostring(k)
            out[#out + 1] = "] = "
            dump(v[k], out, indent .. "    ")
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
    elseif t == "string" then out[#out + 1] = string.format("%q", v)
    else out[#out + 1] = tostring(v) end
end

local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path) return setmetatable({ file = path, data = {} }, LuaSettings) end
function LuaSettings:readSetting(k) return self.data[k] end
function LuaSettings:saveSetting(k, v) self.data[k] = v end
function LuaSettings:flush()
    local out = {}
    dump(self.data, out, "")
    local s = "-- " .. self.file .. "\nreturn " .. table.concat(out) .. "\n"
    local f = io.open(self.file, "w") f:write(s) f:close()
    stats.flush = stats.flush + 1
    stats.flush_bytes = stats.flush_bytes + #s
end
package.loaded["luasettings"] = LuaSettings

-- synthetic data ---------------------------------------------------------
math.randomseed(7)
local syll = { "ka","lo","mi","ra","ten","dor","vel","shan","mor","ith","bel","quin","sa","ro","nel","tar","gan","fi","lu","zen","wy","ash","ock","ber" }
local function word()
    local w = ""
    for _ = 1, math.random(2, 3) do w = w .. syll[math.random(#syll)] end
    return w
end
local vocab = {}
for i = 1, 2500 do vocab[i] = word() end
local function cap(w) return w:sub(1,1):upper() .. w:sub(2) end
local function title()
    local t = {}
    for i = 1, math.random(1, 5) do t[i] = cap(vocab[math.random(#vocab)]) end
    local s = table.concat(t, " ")
    if math.random() < 0.15 then s = s .. ": " .. cap(vocab[math.random(#vocab)]) .. " " .. cap(vocab[math.random(#vocab)]) end
    if math.random() < 0.2 then s = "The " .. s end
    return s
end
local authors = {}
for i = 1, 400 do authors[i] = cap(word()) .. " " .. cap(word()) end

local books = {}
for i = 1, NBOOKS do
    local a = authors[math.random(#authors)]
    books[i] = { id = 100000 + i, title = title(), author = a, authors = a, pages = 300,
        description = string.rep("lorem ipsum dolor ", 20), cover = "https://assets.hardcover.app/x/" .. i .. ".jpg",
        release_date = "2020-01-01", series = (i % 3 == 0) and (cap(word()) .. " Saga") or nil }
end
-- files: ~55% of books on device, rest other books
local fs = { ["/mnt/us/books"] = {} }
local dirs = { "/mnt/us/books" }
for i = 1, 60 do
    local d = "/mnt/us/books/" .. authors[i]:gsub(" ", "_")
    fs[d] = {} table.insert(fs["/mnt/us/books"], d) dirs[#dirs + 1] = d
end
local nfiles, filelist = 0, {}
local function addFile(name)
    local d = dirs[math.random(#dirs)]
    local p = d .. "/" .. name
    if fs[p] then return end
    table.insert(fs[d], p) fs[p] = "file"
    nfiles = nfiles + 1 filelist[#filelist + 1] = p
    -- sidecar dir, like KOReader
    if math.random() < 0.3 then local sdr = p:gsub("%.%w+$", ".sdr") fs[sdr] = {} table.insert(fs[d], sdr) end
end
for i = 1, NBOOKS do
    if math.random() < 0.55 then addFile(books[i].author .. " - " .. books[i].title:gsub(":", " -") .. ".epub") end
end
while nfiles < NFILES do addFile(authors[math.random(#authors)] .. " - " .. title():gsub(":", " -") .. "." .. (math.random() < 0.8 and "epub" or "pdf")) end

local lfs = {
    dir = function(p)
        local list = fs[p]
        if type(list) ~= "table" then error("not a dir") end
        local i = 0
        local names = { ".", ".." }
        for _, c in ipairs(list) do names[#names + 1] = c:match("[^/]+$") end
        return function() i = i + 1 return names[i] end, nil
    end,
    attributes = function(p, what)
        stats.stat = stats.stat + 1
        local v = fs[p]
        if v == nil then return nil end
        local mode = type(v) == "table" and "directory" or "file"
        if what == "mode" then return mode end
        return { mode = mode, size = 1000 }
    end,
}
package.loaded["libs/libkoreader-lfs"] = lfs

-- KOReader stubs -----------------------------------------------------------
local UIManager = stub()
UIManager.scheduleIn = function(_, d, fn) stats.scheduled[#stats.scheduled + 1] = fn end
UIManager.unschedule = function(_, fn)
    for i = #stats.scheduled, 1, -1 do if stats.scheduled[i] == fn then table.remove(stats.scheduled, i) end end
end
package.loaded["ui/uimanager"] = UIManager
for _, m in ipairs({ "ui/widget/buttondialog", "ui/widget/infomessage", "ui/widget/inputdialog", "ui/widget/menu",
    "ui/widget/notification", "ui/widget/confirmbox", "ui/widget/textviewer" }) do
    package.loaded[m] = { new = function(_, o) return o or {} end }
end
package.loaded["ui/network/manager"] = { isOnline = function() return false end, runWhenOnline = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return SCRATCH end, getDataDir = function() return SCRATCH end }
package.loaded["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end, scaleBySize = function(_, x) return x end }, home_dir = "/mnt/us" }
package.loaded["logger"] = { warn = function() end, info = function() end, err = function() end, dbg = function() end }
package.loaded["gettext"] = function(x) return x end
package.loaded["ffi/util"] = { template = function(f, ...) local a = { ... } return (f:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end)) end,
    realpath = function(p) stats.realpath = stats.realpath + 1 return p end }
package.loaded["json"] = { encode = function() return "" end, decode = function() return {} end }
package.loaded["socket"] = { gettime = os.clock }
package.loaded["socket.http"] = stub()
package.loaded["ltn12"] = stub()
package.loaded["ssl.https"] = stub()
-- BookInfoManager: one SQLite lookup per call on a device
package.loaded["bookinfomanager"] = { getBookInfo = function(_, path) stats.bookinfo = stats.bookinfo + 1 return nil end }
-- ReadCollection (KOReader 2024.04+)
local RC = { coll = { favorites = {} } }
function RC:addCollection(n) self.coll[n] = {} end
function RC:addItem(p, n) self.coll[n][p] = { file = p } end
function RC:removeItem(p, n) if self.coll[n] then self.coll[n][p] = nil end end
function RC:removeCollection(n) self.coll[n] = nil end
function RC:write() end
package.loaded["readcollection"] = RC

local GSettings = { data = { home_dir = "/mnt/us" } }
function GSettings:readSetting(k) return self.data[k] end
function GSettings:saveSetting(k, v) self.data[k] = v end
function GSettings:flush() end
_G.G_reader_settings = GSettings

local HardcoverUI = require("hardcoverui")
local Collections = require("collections")
local Hardcover = require("koirc/hardcover")

-- cache: 25 lists of 40, 60 series (from books with series), shelves
local cache = { lists = { lists = {} }, series = { following = {}, started = {} } }
local nb = 0
local function take(n) local t = {} for _ = 1, n do nb = nb % NBOOKS + 1 t[#t + 1] = books[nb] end return t end
for i = 1, 25 do
    cache.lists.lists[i] = { id = i, name = "List " .. i, books_count = 40 }
    cache["books:list:" .. i] = take(40)
end
for i = 1, 60 do
    local sr = { id = 500 + i, name = "Series " .. i }
    table.insert(i % 2 == 0 and cache.series.following or cache.series.started, sr)
    cache["books:series:" .. sr.id] = take(8)
end
for _, st in ipairs({ 1, 2, 3, 5 }) do cache["books:status:" .. st] = take(math.floor(NBOOKS / 4)) end

local settings = { hardcover_files = {}, hardcover_token = "x" }
local plugin = { settings = settings, saveSettings = function() end, getDownloadDir = function() return "/mnt/us/books" end }
local hc = HardcoverUI.new(plugin)
hc:cache()
hc:setCache(cache)
stats.flush = 0 stats.flush_bytes = 0

local function run(name, fn)
    local s0, f0, b0, rp0 = stats.stat, stats.flush, stats.bookinfo, stats.realpath
    collectgarbage() collectgarbage()
    local m0 = collectgarbage("count")
    local t0 = clock()
    local r = fn()
    local dt = clock() - t0
    print(string.format("%-46s %8.1f ms  stats=%-6d flushes=%-2d bookinfo=%-5d realpath=%-5d mem+%dKB",
        name, dt * 1000, stats.stat - s0, stats.flush - f0, stats.bookinfo - b0, stats.realpath - rp0,
        math.floor(collectgarbage("count") - m0)))
    return r
end
local function drain() local s = stats.scheduled stats.scheduled = {} for _, fn in ipairs(s) do fn() end end

print(string.format("books=%d files=%d cached books=%d", NBOOKS, nfiles, #hc:allCachedBooks()))
local results = {}
run("first mirror (cold: scan + match)", function() Collections.mirror(hc) end)
run("autoAttachAll (Refresh attached books)", function() return hc:autoAttachAll() end)
local attached = 0 for _ in pairs(settings.hardcover_files) do attached = attached + 1 end
print("  attached:", attached)
run("collections mirror (warm)", function() return Collections.mirror(hc) end)
run("applySync (no network; save + attach)", function() hc:applySync(cache, cache, nil, false, { meta = { x = 1 }, goals = {} }) end)
run("  ...then rebuild collections from menu", function() drain() Collections.mirror(hc) end)
run("background applySync (quiet)", function() hc:applySync(cache, cache, nil, true, { meta = { x = 1 }, goals = {} }) end)
run("  ...then rebuild collections from menu", function() drain() Collections.mirror(hc) end)
-- book open on an unmatched file (not a Hardcover book) and a matched one
local some = filelist[#filelist]
run("bookForFile (unmatched file, first open)", function() return hc:bookForFile(some, { title = "Nothing Here" }) end)
local mpath = settings.hardcover_files[tostring(books[2].id)] or filelist[1]
run("bookForFile (attached file)", function() return hc:bookForFile(mpath) end)
-- list open: refreshBooks on a 375-book shelf
hc.books_menu = { switchItemTable = function() end }
hc.source = { kind = "status", id = 1, name = "Want" }
hc.books = cache["books:status:1"]
run("refreshBooks (375 books, warm)", function() hc:refreshBooks() end)
run("refreshBooks again", function() hc:refreshBooks() end)
run("download: addFile + list redraw", function() hc:addFile("/mnt/us/books/New - Book.epub") hc:refreshBooks() drain() end)
-- matching results fingerprint (to compare before/after)
local fp = {}
for _, b in ipairs(books) do fp[#fp + 1] = tostring(Hardcover.findFile(b, hc:localFiles())) end
local att = {}
for k, v in pairs(settings.hardcover_files) do att[#att + 1] = k .. "=" .. tostring(v) end
table.sort(att)
local coll = {}
for n, c in pairs(RC.coll) do for p in pairs(c) do coll[#coll + 1] = n .. "|" .. p end end
table.sort(coll)
local f = io.open(SCRATCH .. "/fingerprint.txt", "w")
f:write(table.concat(fp, "\n"), "\n--\n", table.concat(att, "\n"), "\n--\n", table.concat(coll, "\n"), "\n") f:close()
print("collections entries:", #coll, "store file KB:", math.floor(stats.flush_bytes / math.max(1, stats.flush) / 1024))
