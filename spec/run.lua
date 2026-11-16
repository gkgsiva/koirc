-- Test runner: luajit spec/run.lua  (needs LuaSocket and python3 for fixtures)
package.path = "./ircbooks.koplugin/?.lua;" .. package.path

local socket = require("socket")
local proto = require("koirc/proto")
local results = require("koirc/results")
local unzip = require("koirc/unzip")
local Fetcher = require("koirc/fetcher")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local tmp = os.getenv("TMPDIR") or "/tmp"
tmp = tmp .. "/koirc-spec-" .. tostring(os.time()) .. tostring(math.random(1e6))
os.execute("mkdir -p '" .. tmp .. "/work' '" .. tmp .. "/books'")

local function readFile(p) local f = assert(io.open(p, "rb")) local d = f:read("*a") f:close() return d end
local function writeFile(p, d) local f = assert(io.open(p, "wb")) f:write(d) f:close() end

-- Fixtures built with Python's zipfile (independent zip implementation).
local function pyzip(out, members, method, level)
    local script = tmp .. "/mk.py"
    local lines = { "import zipfile,sys",
        string.format("z=zipfile.ZipFile(%q,'w',%s%s)", out, method,
            level and (", compresslevel=" .. level) or "") }
    for name, src in pairs(members) do
        lines[#lines + 1] = string.format("z.write(%q, %q)", src, name)
    end
    lines[#lines + 1] = "z.close()"
    writeFile(script, table.concat(lines, "\n"))
    assert(os.execute("python3 -I '" .. script .. "'") == 0 or true)
end

local RESULTS_TXT = table.concat({
    "Search results from SearchOok v3.0",
    "Searched 12 bots for \"sanderson mistborn\" and found 3 matches.",
    "",
    "!Oatmeal Brandon Sanderson - Mistborn 01 - The Final Empire.epub  ::INFO:: 1.2MB",
    "!Dumbledore Brandon Sanderson - Mistborn 01 - The Final Empire.mobi ::INFO:: 950.3KB",
    "!Oatmeal Brandon Sanderson - Mistborn 01 - The Final Empire.epub  ::INFO:: 1.2MB",
    "!Bsk Sanderson, Brandon - Mistborn (retail) (epub).rar ::HASH:: abc ::INFO:: 3.1MB",
    "!pondering Caf\233 Stories.epub", -- latin-1 byte
}, "\r\n")

test("plugin methods called from other files exist", function()
    -- A method removed from main.lua but still called by hardcoverui.lua
    -- crashes KOReader (v1.8-v1.10.2: closeResults on "Next book").
    local dir = "ircbooks.koplugin/"
    local all = ""
    for _, f in ipairs({ "main.lua", "hardcoverui.lua", "hcextras.lua" }) do
        local ok, d = pcall(readFile, dir .. f)
        if ok then all = all .. d end
    end
    for _, f in ipairs({ "hardcoverui.lua", "hcextras.lua" }) do
        local ok, d = pcall(readFile, dir .. f)
        if ok then
            for m in d:gmatch("self%.plugin:([%w_]+)%(") do
                assert(all:find("function IrcBooks[:.]" .. m .. "%f[^%w_]"), "missing IrcBooks:" .. m)
            end
        end
    end
    local main = readFile(dir .. "main.lua")
    for m in main:gmatch("self:([%w_]+)%(") do
        assert(all:find("function [%w_]+[:.]" .. m .. "%f[^%w_]") or main:find("%." .. m .. "%s*=%s*function"),
            "missing self:" .. m .. " in main.lua")
    end
end)

test("parseLine", function()
    local m = proto.parseLine(":nick!user@host PRIVMSG #ebooks :hello there\r\n")
    eq(m.nick, "nick") eq(m.command, "PRIVMSG") eq(m.params[1], "#ebooks") eq(m.params[2], "hello there")
    m = proto.parseLine("PING :irc.example.net")
    eq(m.command, "PING") eq(m.params[1], "irc.example.net")
    m = proto.parseLine("@time=x :srv 001 me :Welcome")
    eq(m.command, "001") eq(m.params[1], "me")
end)

test("parseDccSend", function()
    local o = proto.parseDccSend('SEND "My Book - Title.epub" 2130706433 5000 12345')
    eq(o.filename, "My Book - Title.epub") eq(o.host, "127.0.0.1") eq(o.port, 5000) eq(o.size, 12345)
    o = proto.parseDccSend("SEND SearchOok_results_for_x.txt.zip 3232235777 40000 999")
    eq(o.filename, "SearchOok_results_for_x.txt.zip") eq(o.host, "192.168.1.1")
    o = proto.parseDccSend("SEND Unquoted name with spaces.epub 2130706433 6000 10")
    eq(o.filename, "Unquoted name with spaces.epub") eq(o.port, 6000)
    o = proto.parseDccSend('SEND "f.epub" 2130706433 0 10 77')
    eq(o.passive, true) eq(o.token, "77")
end)

test("safeFilename", function()
    eq(proto.safeFilename("../../etc/passwd"), "passwd")
    eq(proto.safeFilename("..\\x.epub"), "x.epub")
    eq(proto.safeFilename("a:b?.epub"), "a_b_.epub")
    eq(proto.safeFilename(".."), "download")
end)

test("results.parse", function()
    local list = results.parse(RESULTS_TXT)
    eq(#list, 4, "dedup")
    eq(list[1].bot, "Oatmeal")
    eq(list[1].title, "Brandon Sanderson - Mistborn 01 - The Final Empire.epub")
    eq(list[1].request, "!Oatmeal Brandon Sanderson - Mistborn 01 - The Final Empire.epub")
    eq(list[1].size, "1.2MB") eq(list[1].ext, "epub")
    eq(list[2].size, "950.3KB")
    eq(list[3].request, "!Bsk Sanderson, Brandon - Mistborn (retail) (epub).rar")
    eq(list[3].ext, "rar")
    eq(list[4].title, "Caf\195\169 Stories.epub", "latin-1 converted")
    eq(#results.filter(list, "epub"), 2)
    eq(#results.filter(list, "epub, mobi"), 3)
    eq(#results.filter(list, ""), 4)
    eq(#results.search(list, "final EMPIRE"), 2)
    eq(#results.search(list, "empire retail"), 0)
    eq(#results.search(list, "bsk"), 1, "matches bot name")
    eq(#results.search(list, "  "), 4)
    local fm = results.formats(list)
    eq(fm[1].ext, "epub") eq(fm[1].count, 2) eq(#fm, 3)
end)

-- Text that exercises stored, fixed and dynamic Huffman blocks.
local parts = {}
for i = 1, 4000 do parts[#parts + 1] = "!Bot" .. (i % 7) .. " Author " .. i .. " - Title " .. (i * 7919 % 1000) .. ".epub ::INFO:: " .. (i % 10) .. ".1MB\n" end
local BIG = table.concat(parts)
local rnd = {}
math.randomseed(42)
for i = 1, 70000 do rnd[i] = string.char(math.random(0, 255)) end
local RANDOM = table.concat(rnd)

test("unzip (deflate/stored, various levels)", function()
    writeFile(tmp .. "/big.txt", BIG)
    writeFile(tmp .. "/rnd.bin", RANDOM)
    writeFile(tmp .. "/small.txt", "hi")
    for _, cfg in ipairs({ { "zipfile.ZIP_DEFLATED", 1 }, { "zipfile.ZIP_DEFLATED", 9 }, { "zipfile.ZIP_STORED" } }) do
        local out = tmp .. "/t.zip"
        os.remove(out)
        pyzip(out, { ["big.txt"] = tmp .. "/big.txt", ["dir/rnd.bin"] = tmp .. "/rnd.bin", ["small.txt"] = tmp .. "/small.txt" }, cfg[1], cfg[2])
        local data = readFile(out)
        assert(unzip.isZip(data))
        local files = assert(unzip.extractAll(data))
        local byname = {}
        for _, f in ipairs(files) do byname[f.name] = f.data end
        eq(byname["big.txt"], BIG, cfg[1])
        eq(byname["dir/rnd.bin"], RANDOM, cfg[1])
        eq(byname["small.txt"], "hi", cfg[1])
    end
end)

-------------------------------------------------------------------------------
-- Fake IRC network: one server + search bot + book bot, all on localhost.
-------------------------------------------------------------------------------
local function newServer(opts)
    local srv = { lines = {}, dccs = {}, log = {} }
    srv.listener = assert(socket.bind("127.0.0.1", 0))
    srv.listener:settimeout(0)
    srv.port = select(2, srv.listener:getsockname())
    local function send(line) srv.client:send(line .. "\r\n") end
    local function offer(from, filename, content, quoted)
        local l = assert(socket.bind("127.0.0.1", 0))
        l:settimeout(0)
        local port = select(2, l:getsockname())
        table.insert(srv.dccs, { listener = l, content = content, sent = 0, acks = 0, port = port, cut = srv.cut_next })
        srv.cut_next = nil
        local fname = quoted and ('"' .. filename .. '"') or filename
        send(string.format(":%s!bot@h PRIVMSG %s :\1DCC SEND %s 2130706433 %d %d\1", from, srv.nick, fname, port, #content))
    end
    function srv:step()
        if not self.client then
            local c = self.listener:accept()
            if c then c:settimeout(0) self.client = c self.buf = "" end
        end
        if self.client then
            local d, err, partial = self.client:receive(8192)
            self.buf = self.buf .. (d or partial or "")
            while true do
                local line, rest = self.buf:match("^([^\n]*)\n(.*)$")
                if not line then break end
                self.buf = rest
                line = line:gsub("\r$", "")
                table.insert(self.log, line)
                local m = proto.parseLine(line)
                if m.command == "NICK" then
                    if opts.nick_taken and not self.rejected then
                        self.rejected = true
                        send(":srv 433 * " .. m.params[1] .. " :Nickname is already in use")
                    else
                        self.nick = m.params[1]
                    end
                end
                if m.command == "USER" then self.got_user = true end
                if m.command == "USER" or m.command == "NICK" then
                    if self.nick and self.got_user and not self.welcomed then
                        self.welcomed = true
                        send(":srv PING :check")
                        send(":srv 001 " .. self.nick .. " :Welcome")
                    end
                elseif m.command == "PONG" then
                    self.ponged = true
                elseif m.command == "JOIN" then
                    send(":" .. self.nick .. "!u@h JOIN :" .. m.params[1])
                    if opts.names then send(":srv 353 " .. self.nick .. " = " .. m.params[1] .. " :" .. opts.names) end
                    send(":srv 366 " .. self.nick .. " " .. m.params[1] .. " :End of /NAMES list.")
                elseif m.command == "PRIVMSG" and m.params[1] == "Cutter" then
                    local port, pos = m.params[2]:match("DCC RESUME .- (%d+) (%d+)\1")
                    self.resume_asked = (self.resume_asked or 0) + 1
                    for _, d in ipairs(self.dccs) do
                        if d.port == tonumber(port) and not opts.no_resume then
                            d.sent = tonumber(pos)
                            d.resumed = true
                            send(string.format(":Cutter!c@h PRIVMSG %s :\1DCC ACCEPT file.epub %s %s\1", self.nick, port, pos))
                        end
                    end
                elseif m.command == "PRIVMSG" and m.params[1] == "#ebooks" then
                    local text = m.params[2]
                    local q = text:match("^@search (.*)$")
                    if q == "nothing" then
                        send(":Search!s@h NOTICE " .. self.nick .. " :Sorry, your search for \"nothing\" returned no matches.")
                    elseif q then
                        send(":Search!s@h NOTICE " .. self.nick .. " :Your search for \"" .. q .. "\" has been accepted. Searching...")
                        offer("Search", "SearchOok_results_for_" .. q:gsub(" ", "_") .. ".txt.zip", opts.results_zip)
                    elseif text:match("^!Nope ") then
                        send(":Nope!n@h NOTICE " .. self.nick .. " :Sorry, file not found in my list.")
                    elseif text:match("^!Leaver ") then
                        send(":Leaver!l@h QUIT :Ping timeout")
                    elseif text:match("^!Cutter ") then
                        -- Sends half the file the first time, then supports DCC RESUME.
                        self.cut_next = (not self.cut_done) and math.floor(#opts.book / 2) or nil
                        self.cut_done = true
                        offer("Cutter", text:match("^!Cutter (.*)$"), opts.book, true)
                    elseif text:match("^!Oatmeal ") then
                        send(":Oatmeal!o@h NOTICE " .. self.nick .. " :\2Request Accepted\2 - Queue position 1")
                        -- random bot chatter / wrong-sender DCC must be ignored
                        send(":Stranger!x@h PRIVMSG " .. self.nick .. " :\1DCC SEND evil.exe 2130706433 1 10\1")
                        offer("Oatmeal", text:match("^!Oatmeal (.*)$"), opts.book, true)
                    end
                end
            end
        end
        for _, d in ipairs(self.dccs) do
            if not d.conn and not d.closed then
                local c = d.listener:accept()
                if c then c:settimeout(0) d.conn = c end
            end
            if d.conn then
                if d.cut and d.sent >= d.cut then
                    d.conn:close() d.conn = nil d.closed = true
                elseif d.sent < #d.content then
                    local limit = d.cut and math.min(d.cut, d.sent + 4096) or (d.sent + 4096)
                    local chunk = d.content:sub(d.sent + 1, limit)
                    local last, _, part = d.conn:send(chunk)
                    d.sent = d.sent + (last or part or 0)
                end
                local a = d.conn and d.conn:receive(4)
                if a and #a == 4 then d.acks = d.acks + 1 end
                if d.conn and d.sent >= #d.content then
                    d.conn:close() d.conn = nil d.closed = true
                end
            end
        end
    end
    return srv
end

local function run(fetcher, srv, cond, secs)
    local deadline = socket.gettime() + (secs or 20)
    while not cond() do
        if socket.gettime() > deadline then error("timeout") end
        fetcher:step()
        srv:step()
        socket.sleep(0.002)
    end
end

Fetcher.JOIN_SETTLE = 0

local function scenario(opts)
    writeFile(tmp .. "/results.txt", RESULTS_TXT)
    os.remove(tmp .. "/res.zip")
    pyzip(tmp .. "/res.zip", { ["SearchOok_results.txt"] = tmp .. "/results.txt" }, "zipfile.ZIP_DEFLATED")
    local srv = newServer{ results_zip = readFile(tmp .. "/res.zip"), book = opts.book, nick_taken = opts.nick_taken, names = opts.names, no_resume = opts.no_resume }
    local f = Fetcher.new{
        socket = socket,
        -- The fake books are random bytes: check files only when a test asks.
        config = { host = "127.0.0.1", port = srv.port, nick = "kouser", channel = "#ebooks", search_cmd = "@search",
                   quality_check = opts.quality or false },
        work_dir = tmp .. "/work",
        log = os.getenv("VERBOSE") and print or nil,
    }
    return srv, f
end

test("end to end: search, pick, download", function()
    local book = RANDOM .. BIG -- > 1 DCC chunk
    local srv, f = scenario{ book = book, nick_taken = true }
    local res, err, statuses = nil, nil, {}
    assert(f:search("sanderson mistborn", {
        on_status = function(s) statuses[#statuses + 1] = s end,
        on_done = function(r) res = r end,
        on_error = function(e) err = e end,
    }))
    run(f, srv, function() return res or err end)
    assert(not err, err)
    eq(#res, 4)
    assert(srv.ponged, "answered PING")
    assert(f.nick ~= "kouser", "picked another nick after 433")
    eq(srv.log[#srv.log], "PRIVMSG #ebooks :@search sanderson mistborn")
    -- results file was cleaned up
    eq(io.open(tmp .. "/work/SearchOok_results_for_sanderson_mistborn.txt.zip"), nil)

    local path
    assert(f:download(res[1], tmp .. "/books", {
        on_status = function(s) statuses[#statuses + 1] = s end,
        on_done = function(p) path = p end,
        on_error = function(e) err = e end,
    }))
    run(f, srv, function() return path or err end)
    assert(not err, err)
    eq(path, tmp .. "/books/Brandon Sanderson - Mistborn 01 - The Final Empire.epub")
    eq(readFile(path), book)
    assert(srv.dccs[2].acks > 0, "sent DCC acks")
    local saw_bot = false
    for _, s in ipairs(statuses) do if s:find("Request Accepted - Queue", 1, true) then saw_bot = true end end
    assert(saw_bot, "bot notice relayed without formatting")

    -- downloading again keeps the first copy
    path = nil
    assert(f:download(res[1], tmp .. "/books", { on_done = function(p) path = p end, on_error = function(e) err = e end }))
    run(f, srv, function() return path or err end)
    eq(path, tmp .. "/books/Brandon Sanderson - Mistborn 01 - The Final Empire (1).epub")
    f:disconnect()
end)

test("no results notice ends search with empty list", function()
    local srv, f = scenario{ book = "x" }
    local res, err
    f:search("nothing", { on_done = function(r) res = r end, on_error = function(e) err = e end })
    run(f, srv, function() return res or err end)
    assert(not err, err)
    eq(#res, 0)
    f:disconnect()
end)

test("connection refused is reported", function()
    local l = socket.bind("127.0.0.1", 0)
    local port = select(2, l:getsockname())
    l:close()
    local f = Fetcher.new{ socket = socket, work_dir = tmp,
        config = { host = "127.0.0.1", port = port, nick = "x", channel = "#ebooks" } }
    local err
    f:search("x", { on_error = function(e) err = e end })
    local deadline = socket.gettime() + 10
    while not err and socket.gettime() < deadline do f:step() socket.sleep(0.01) end
    assert(err and err:find("Disconnected"), tostring(err))
end)

test("zipped book is unpacked after download", function()
    writeFile(tmp .. "/inner.epub", "EPUBDATA" .. BIG)
    os.remove(tmp .. "/book.zip")
    pyzip(tmp .. "/book.zip", { ["Some Author - Book.epub"] = tmp .. "/inner.epub" }, "zipfile.ZIP_DEFLATED")
    local srv, f = scenario{ book = readFile(tmp .. "/book.zip") }
    local path, err
    -- download without searching first
    f:download({ bot = "Oatmeal", title = "Some Author - Book.zip", request = "!Oatmeal Some Author - Book.zip" },
        tmp .. "/books", { on_done = function(p) path = p end, on_error = function(e) err = e end })
    run(f, srv, function() return path or err end)
    assert(not err, err)
    eq(path, tmp .. "/books/Some Author - Book.epub")
    eq(readFile(path), "EPUBDATA" .. BIG)
    eq(io.open(tmp .. "/books/Some Author - Book.zip"), nil, "zip removed")
    f:disconnect()
end)


test("resume: broken transfer continues with DCC RESUME", function()
    local book = RANDOM .. BIG
    local srv, f = scenario{ book = book }
    local entry = { bot = "Cutter", title = "Resume Me.epub", request = "!Cutter Resume Me.epub" }
    local path, err, reason
    os.remove(tmp .. "/books/Resume Me.epub")
    f:download(entry, tmp .. "/books", { on_done = function(p) path = p end, on_error = function(e, r) err, reason = e, r end })
    run(f, srv, function() return path or err end)
    eq(reason, "interrupted", tostring(err))
    local part = readFile(tmp .. "/books/Resume Me.epub.part")
    eq(#part, math.floor(#book / 2), "half kept")
    err = nil
    f:download(entry, tmp .. "/books", { on_done = function(p) path = p end, on_error = function(e, r) err, reason = e, r end })
    run(f, srv, function() return path or err end)
    assert(not err, err)
    eq(path, tmp .. "/books/Resume Me.epub")
    eq(srv.resume_asked, 1, "asked to resume")
    eq(readFile(path), book, "file whole after resume")
    eq(io.open(path .. ".part"), nil, "part gone")
    eq(io.open(path .. ".part.info"), nil, "info gone")
    f:disconnect()
end)

test("resume: bot that ignores RESUME gets the whole file again", function()
    local book = RANDOM .. "tail"
    local srv, f = scenario{ book = book, no_resume = true }
    local old_wait = Fetcher.RESUME_WAIT
    Fetcher.RESUME_WAIT = 0.3
    local entry = { bot = "Cutter", title = "Ignore Me.epub", request = "!Cutter Ignore Me.epub" }
    local path, err, reason
    f:download(entry, tmp .. "/books", { on_done = function(p) path = p end, on_error = function(e, r) err, reason = e, r end })
    run(f, srv, function() return path or err end)
    eq(reason, "interrupted")
    err = nil
    f:download(entry, tmp .. "/books", { on_done = function(p) path = p end, on_error = function(e, r) err = e end })
    run(f, srv, function() return path or err end)
    Fetcher.RESUME_WAIT = old_wait
    assert(not err, err)
    eq(readFile(path), book)
    f:disconnect()
end)

-------------------------------------------------------------------------------
-- Hardcover
-------------------------------------------------------------------------------

local Hardcover = require("koirc/hardcover")

-- Minimal JSON encoder for the request body; responses are handed back as
-- tables by the fake transport.
local function jsonEncode(v)
    local t = type(v)
    if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(x) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function fakeClient(responder)
    local calls = {}
    local c = Hardcover.new{
        token = function() return "Bearer  abc.def\n" end,
        json = { encode = jsonEncode, decode = function() error("not used") end },
        post = function(url, headers, body)
            calls[#calls + 1] = { url = url, headers = headers, body = body }
            return responder(body)
        end,
    }
    return c, calls
end

local function bookRow(id, title, author, series, pos)
    return { id = id, title = title,
        contributions = author and {{ author = { name = author } }} or {},
        book_series = series and {{ position = pos, series = { name = series } }} or {} }
end

test("hardcover: lists and auth header", function()
    local c, calls = fakeClient(function()
        return 200, { data = { me = {{ id = 7, username = "siva",
            lists = {{ id = 3, name = "Cosmere", books_count = 2 }} }} } }
    end)
    local res = assert(c:getLists())
    eq(res.user.username, "siva") eq(#res.lists, 1) eq(res.lists[1].name, "Cosmere") eq(res.lists[1].count, 2)
    eq(calls[1].url, "https://api.hardcover.app/v1/graphql")
    eq(calls[1].headers.authorization, "Bearer abc.def")
    eq(calls[1].headers["content-length"], tostring(#calls[1].body))
end)

test("hardcover: list books keep order and metadata", function()
    local c, calls = fakeClient(function()
        return 200, { data = { lists = {{ id = 3, name = "Cosmere", list_books = {
            { position = 1, book = bookRow(10, "Mistborn: The Final Empire", "Brandon Sanderson", "Mistborn", 1) },
            { position = 2, book = bookRow(11, "The Well of Ascension", "Brandon Sanderson", "Mistborn", 2) },
            { position = 3, book = bookRow(10, "Mistborn: The Final Empire", "Brandon Sanderson") },
        } }} } }
    end)
    local books = assert(c:getListBooks(3))
    eq(#books, 2, "duplicate removed")
    eq(books[1].title, "Mistborn: The Final Empire") eq(books[1].author, "Brandon Sanderson")
    eq(books[1].series, "Mistborn #1") eq(books[2].id, 11)
    assert(calls[1].body:find('"id":3'), calls[1].body)
end)

test("hardcover: series tracker", function()
    local c = fakeClient(function(body)
        if body:find("IrcBooksSeriesBooks", 1, true) then
            return 200, { data = { series = {{ id = 9, name = "Harry Potter", book_series = {
                { position = 1, book = bookRow(1, "Harry Potter and the Philosopher's Stone", "J.K. Rowling") },
                { position = 1, book = bookRow(2, "Harry Potter and the Sorcerer's Stone", "J.K. Rowling") },
                { position = 1.5, book = bookRow(3, "Short Story", "J.K. Rowling") },
                { position = 2, book = bookRow(4, "Harry Potter and the Chamber of Secrets", "J.K. Rowling") },
            } }} } }
        end
        return 200, { data = { me = {{
            follows = { { followable_type = "User", series = nil }, { followable_type = "Series", series = { id = 9, name = "Harry Potter", primary_books_count = 7 } } },
            user_books = { { book = { book_series = { { series = { id = 9, name = "Harry Potter" } }, { series = { id = 5, name = "Discworld", primary_books_count = 41 } } } } } },
        }} } }
    end)
    local res = assert(c:getSeries())
    eq(#res.following, 1) eq(res.following[1].name, "Harry Potter") eq(res.following[1].count, 7)
    eq(#res.started, 1) eq(res.started[1].name, "Discworld")
    local books = assert(c:getSeriesBooks(9))
    eq(#books, 2, "one book per whole position")
    eq(books[1].id, 1) eq(books[1].series, "Harry Potter #1") eq(books[2].series, "Harry Potter #2")
end)

test("hardcover: errors", function()
    local c = fakeClient(function() return 401, "" end)
    local r, err = c:getLists()
    eq(r, nil) assert(err:find("API key"), err)
    c = fakeClient(function() return 200, { errors = {{ message = "field 'x' not found" }} } end)
    r, err = c:getLists()
    assert(err:find("field 'x' not found"), err)
    c = fakeClient(function() return nil, "timeout" end)
    r, err = c:getLists()
    assert(err:find("timeout"), err)
    local empty = Hardcover.new{ token = "", json = {}, post = function() error("no call") end }
    r, err = empty:getLists()
    assert(err:find("No Hardcover API key"), err)
end)

test("hardcover: match books with files", function()
    local files = {
        Hardcover.fileEntry("/b/Brandon Sanderson - Mistborn 01 - The Final Empire.epub"),
        Hardcover.fileEntry("/b/Dune - Frank Herbert.mobi"),
        Hardcover.fileEntry("/b/Lévi, Ann - Café Society.epub"),
    }
    local function find(title, author) return Hardcover.findFile({ title = title, author = author }, files) end
    eq(find("Mistborn: The Final Empire", "Brandon Sanderson"), files[1].path)
    eq(find("The Final Empire", "Brandon Sanderson"), files[1].path)
    eq(find("The Well of Ascension", "Brandon Sanderson"), nil)
    eq(find("Mistborn: The Hero of Ages", "Brandon Sanderson"), nil)
    eq(find("Dune", "Frank Herbert"), files[2].path)
    eq(find("Dune", "Someone Else"), nil, "short title needs author")
    eq(find("Dune Messiah", "Frank Herbert"), nil)
    eq(find("Café Society (Annotated)", "Ann Lévi"), files[3].path)
end)

test("hardcover: scan folders", function()
    os.execute("mkdir -p '" .. tmp .. "/lib/sub/deeper' '" .. tmp .. "/lib/x.sdr'")
    writeFile(tmp .. "/lib/One.epub", "x")
    writeFile(tmp .. "/lib/sub/deeper/Two.PDF", "x")
    writeFile(tmp .. "/lib/notes.jpg", "x")
    writeFile(tmp .. "/lib/x.sdr/metadata.epub.lua", "x")
    local fakeLfs = {
        dir = function(d)
            local p = io.popen("ls -1a '" .. d .. "' 2>/dev/null")
            local names = {}
            for n in p:lines() do names[#names + 1] = n end
            p:close()
            local i = 0
            return function() i = i + 1 return names[i] end
        end,
        attributes = function(path)
            local p = io.popen("test -d '" .. path .. "' && echo d || (test -f '" .. path .. "' && echo f)")
            local r = p:read("*l") p:close()
            return r == "d" and "directory" or r == "f" and "file" or nil
        end,
    }
    local files = Hardcover.scan(fakeLfs, { tmp .. "/lib/" }, 4)
    local names = {}
    for _, f in ipairs(files) do names[#names + 1] = f.path:match("[^/]+$") end
    table.sort(names)
    eq(table.concat(names, ","), "One.epub,Two.PDF")
end)

test("hardcover: search query and token cleanup", function()
    eq(Hardcover.searchQuery({ title = "Mistborn: The Final Empire", author = "Brandon Sanderson" }),
        "Brandon Sanderson Mistborn The Final Empire")
    eq(Hardcover.searchQuery({ title = "Atomic Habits: An Easy & Proven Way to Build Good Habits", author = "James Clear" }),
        "James Clear Atomic Habits")
    eq(Hardcover.searchQuery({ title = "Dune (Dune Chronicles, #1)" }), "Dune")
    eq(Hardcover.cleanToken("  Bearer eyJ.abc\n"), "eyJ.abc")
end)


test("results: sizes, preferred formats and sorting", function()
    eq(results.sizeBytes("1.5MB"), 1572864) eq(results.sizeBytes("950,3 KB"), 973107)
    eq(results.sizeBytes("12345"), 12345) eq(results.sizeBytes(nil), nil)
    local prefs = results.parseFormats("EPUB, mobi pdf, epub")
    eq(table.concat(prefs, ","), "epub,mobi,pdf")
    local list = {
        { title = "A.pdf", ext = "pdf", size = "3MB", bot = "x" },
        { title = "B.mobi", ext = "mobi", size = "500KB", bot = "x" },
        { title = "C.rar", ext = "rar", size = "1KB", bot = "x" },
        { title = "D.epub.zip", ext = "zip", size = "2MB", bot = "x" },
        { title = "E.epub", ext = "epub", bot = "x" },
    }
    eq(results.bookExt(list[4]), "epub")
    local function names(l) local t = {} for i, e in ipairs(l) do t[i] = e.title:sub(1, 1) end return table.concat(t) end
    eq(names(results.sort(list, "format", prefs)), "DEBAC")
    eq(names(results.sort(list, "size_asc", prefs)), "CBDAE")
    eq(names(results.sort(list, "size_desc", prefs)), "ADBCE")
    eq(names(results.sort(list, "name", prefs)), "ABCDE")
    eq(names(results.sort(list, "none", prefs)), "ABCDE")
    eq(names(results.filterSize(list, 2 * 1048576)), "BCDE", "unknown size kept")
    eq(#results.filterSize(list, 0), 5)
end)

test("hardcover: best matching IRC result", function()
    local list = results.parse(table.concat({
        "!a Brandon Sanderson - Mistborn 02 - The Well of Ascension.epub ::INFO:: 1MB",
        "!b Brandon Sanderson - Mistborn 01 - The Final Empire.mobi ::INFO:: 1MB",
        "!c Brandon Sanderson - Mistborn 01 - The Final Empire.epub ::INFO:: 1MB",
        "!d Brandon Sanderson - Mistborn Trilogy Omnibus The Final Empire Well of Ascension Hero of Ages.epub ::INFO:: 5MB",
        "!e Someone Else - Empire.epub",
    }, "\n"))
    local book = { title = "Mistborn: The Final Empire", author = "Brandon Sanderson", authors = "Brandon Sanderson" }
    local prefs = results.parseFormats("epub, mobi")
    local ranked = Hardcover.rankResults(book, list, function(e) return results.formatRank(e, prefs) end)
    eq(ranked[1].bot, "c", "epub preferred") eq(ranked[2].bot, "b")
    eq(ranked[3].bot, "d", "omnibus last") eq(#ranked, 3)
    eq(#Hardcover.rankResults({ title = "Dune", author = "Frank Herbert" }, list), 0)
    -- Title alone is not enough: the author must match too.
    local other = results.parse("!x Jane Doe - The Final Empire Mistborn.epub\n!y Sanderson - The Final Empire Mistborn.epub")
    ranked = Hardcover.rankResults(book, other)
    eq(#ranked, 1) eq(ranked[1].bot, "y")
    eq(#Hardcover.rankResults({ title = "Good Omens", authors = "Terry Pratchett, Neil Gaiman" },
        results.parse("!z Neil Gaiman - Good Omens.epub")), 1, "any of the authors")
end)

test("hardcover: fuzzy matching", function()
    local function m(book, name) return #Hardcover.rankResults(book, results.parse("!b " .. name)) == 1 end
    local hp = { title = "Harry Potter and the Philosopher's Stone", author = "J.K. Rowling" }
    assert(m(hp, "Rowling, J K - Harry Potter 01 - Philosophers Stone.epub"), "surname first, possessive")
    assert(m(hp, "J. K. Rowling - Harry Potter and the Philosopher Stones.epub"), "plural")
    assert(m(hp, "JK Rowlling - Harry Potter and the Philosophers Stone.epub"), "typo in author")
    assert(m({ title = "The Colour of Magic", author = "Terry Pratchett" }, "Terry Pratchett - The Color of Magic.mobi"), "spelling variant")
    assert(m({ title = "Café Society", author = "Ann Lévi" }, "Ann Levi - Cafe Society.epub"), "accents")
    assert(not m(hp, "J.K. Rowling - Harry Potter and the Chamber of Secrets.epub"), "other book")
    assert(not m({ title = "Dune Messiah", author = "Frank Herbert" }, "Frank Herbert - Dune.epub"), "missing word in short title")
    assert(not m({ title = "Mistborn: The Final Empire", author = "Brandon Sanderson" }, "Brandon Sanderson - The Well of Ascension.epub"))
    -- An exact match ranks above a near miss.
    local ranked = Hardcover.rankResults({ title = "The Colour of Magic", author = "Terry Pratchett" },
        results.parse("!a Terry Pratchett - The Color of Magic.epub\n!b Terry Pratchett - The Colour of Magic.epub"))
    eq(ranked[1].bot, "b")
    eq(Hardcover.distance("colour", "color", 1), 1) eq(Hardcover.distance("stone", "store", 1), 1)
end)

test("hardcover: file metadata and finding the book of a file", function()
    local books = {
        { id = 1, title = "Project Hail Mary", author = "Andy Weir" },
        { id = 2, title = "The Martian", author = "Andy Weir" },
    }
    local f = Hardcover.fileEntry("/b/9780593135204.epub", { title = "The Martian", authors = "Andy Weir" })
    eq(Hardcover.findBook(f, books).id, 2)
    eq(Hardcover.findBook(Hardcover.fileEntry("/b/9780593135204.epub"), books), nil)
    eq(Hardcover.findBook(Hardcover.fileEntry("/b/Weir - Project Hail Mary.epub"), books).id, 1)
end)

test("hardcover: reading status", function()
    local state = { ub = false, calls = {} }
    local c = fakeClient(function(body)
        local name = body:match("IrcBooks(%w+)")
        state.calls[#state.calls + 1] = name
        if name == "UserBook" then
            return 200, { data = { me = {{ user_books = state.ub and { state.ub } or {} }} } }
        elseif name == "InsertUserBook" then
            state.ub = { id = 50, status_id = 2 }
            return 200, { data = { insert_user_book = { id = 50 } } }
        elseif name == "UpdateUserBook" then
            assert(body:find('"id":50'), body)
            state.ub.status_id = 3
            return 200, { data = { update_user_book = { id = 50, error = state.fail } } }
        end
    end)
    eq(c:setStatus(7, Hardcover.STATUS_READING), "set")
    eq(table.concat(state.calls, ","), "UserBook,InsertUserBook")
    eq(c:setStatus(7, Hardcover.STATUS_READING), "unchanged")
    eq(c:setStatus(7, Hardcover.STATUS_READ), "set")
    eq(c:setStatus(7, Hardcover.STATUS_READING), "kept", "never moves a read book back")
    state.ub.status_id = 2
    state.fail = "nope"
    local r, err = c:setStatus(7, Hardcover.STATUS_READ)
    eq(r, nil) assert(err:find("nope"), err)
end)

test("download queue: picks best match, retries, reports", function()
    -- Minimal stand-ins for the KOReader modules the queue uses.
    local scheduled, shown = {}, {}
    package.loaded["ui/uimanager"] = {
        scheduleIn = function(_, _d, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_, fn) assert(fn ~= nil, "unschedule(nil) crashes under ZenOS") for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end end,
        show = function(_, w) shown[#shown + 1] = w end,
    }
    package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o end }
    package.loaded["ui/widget/notification"] = { notify = function() end }
    package.loaded["logger"] = { warn = function() end }
    package.loaded["gettext"] = function(x) return x end
    package.loaded["ffi/util"] = { template = function(f, ...)
        local a = { ... }
        return (f:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
    end }
    local Queue = require("downloadqueue")
    local fetcher = { busy = false, log = {} }
    function fetcher:isBusy() return false end
    function fetcher:cancel() end
    function fetcher:search(q, h)
        self.log[#self.log + 1] = "search " .. q
        if q:find("Dune") then h.on_done({}) return true end
        h.on_done(results.parse(table.concat({
            "!slow Andy Weir - The Martian.epub ::INFO:: 1MB",
            "!fast Andy Weir - The Martian.epub ::INFO:: 1MB",
            "!m Andy Weir - The Martian.mobi ::INFO:: 1MB",
            "!r Andy Weir - The Martian.rar ::INFO:: 1MB",
        }, "\n")))
        return true
    end
    function fetcher:download(e, dir, h)
        self.log[#self.log + 1] = "get " .. e.bot
        if e.bot == "slow" then h.on_error("timeout") else h.on_done(dir .. "/" .. e.title) end
        return true
    end
    local got = {}
    local q = Queue.new{
        fetcher = function() return fetcher end,
        start_ticking = function() end,
        settings = function() return { preferred_formats = "epub, mobi", formats = "" } end,
        download_dir = function() return "/books" end,
        on_book_done = function(book, path) got[#got + 1] = book.id .. "=" .. path end,
    }
    assert(q:start({ { id = 1, title = "The Martian", author = "Andy Weir" }, { id = 2, title = "Dune", author = "Frank Herbert" } }))
    local guard = 0
    while #scheduled > 0 and guard < 50 do
        guard = guard + 1
        table.remove(scheduled, 1)()
    end
    eq(q:isRunning(), false)
    eq(table.concat(fetcher.log, "|"), "search Andy Weir The Martian|get slow|get fast|search Frank Herbert Dune")
    eq(got[1], "1=/books/Andy Weir - The Martian.epub")
    eq(#q.done, 1) eq(#q.failed, 1) eq(q:remaining(), 0)
    assert(shown[#shown].text:find("1 downloaded, 1 not found"), shown[#shown].text)
end)


test("hardcover: series, cover and pages from book rows", function()
    local b = Hardcover.normalizeBook({ id = 5, title = "The Well of Ascension", pages = 763,
        image = { url = "https://assets.hardcover.app/x.jpg" }, description = "Second",
        contributions = {{ author = { name = "Brandon Sanderson" } }},
        book_series = {{ position = 2, series = { id = 99, name = "Mistborn" } }} })
    eq(b.series_id, 99) eq(b.series_pos, 2) eq(b.series_name, "Mistborn") eq(b.pages, 763)
    eq(b.cover, "https://assets.hardcover.app/x.jpg") eq(b.series, "Mistborn #2")
    local books = { { title = "1", series_pos = 1 }, { title = "3", series_pos = 3 }, { title = "2", series_pos = 2 } }
    eq(Hardcover.nextInSeries(books, 1).title, "2") eq(Hardcover.nextInSeries(books, 2).title, "3")
    eq(Hardcover.nextInSeries(books, 3), nil)
end)

test("hardcover: guess author and title from an IRC result", function()
    local g = Hardcover.entryBook({ title = "Brandon Sanderson - Mistborn 01 - The Final Empire (retail).epub" })
    eq(g.author, "Brandon Sanderson") eq(g.title, "The Final Empire")
    g = Hardcover.entryBook({ title = "Just A Title.epub.zip" })
    eq(g.title, "Just A Title") eq(g.author, nil)
    local files = { Hardcover.fileEntry("/b/Sanderson, Brandon - The Final Empire.epub") }
    eq(Hardcover.findFile(Hardcover.entryBook({ title = "Brandon Sanderson - Mistborn 01 - The Final Empire.mobi" }), files),
       files[1].path, "duplicate under another file name")
end)

test("hardcover: reading progress", function()
    local st = { ub = { id = 50, status_id = 2, user_book_reads = {{ id = 8, started_at = "2026-11-01", progress_pages = 10 }} }, bodies = {} }
    local c = fakeClient(function(body)
        local name = body:match("IrcBooks(%w+)")
        st.bodies[#st.bodies + 1] = body
        if name == "UserBook" then return 200, { data = { me = {{ user_books = { st.ub } }} } } end
        if name == "UpdateRead" then return 200, { data = { update_user_book_read = { id = 8 } } } end
        if name == "InsertRead" then return 200, { data = { insert_user_book_read = { id = 9 } } } end
    end)
    eq(c:setProgress(7, 0.5, 400, "2026-11-05"), "set")
    local last = st.bodies[#st.bodies]
    assert(last:find("UpdateRead") and last:find('"progress_pages":200') and last:find("2026%-11%-01"), last)
    st.ub.user_book_reads[1].progress_pages = 200
    eq(c:setProgress(7, 0.5, 400, "2026-11-05"), "unchanged")
    st.ub.user_book_reads[1].finished_at = "2026-11-02"
    eq(c:setProgress(7, 0.1, 400, "2026-11-05"), "set")
    assert(st.bodies[#st.bodies]:find("InsertRead"), "new read after a finished one")
    st.ub.status_id = 3
    eq(c:setProgress(7, 0.2, 400, "2026-11-05"), "unchanged", "read books are left alone")
    local r, err = c:setProgress(7, 0.2, nil)
    eq(r, nil) assert(err:find("page count"))
end)

test("hardcover: shelf moves can move a Read book", function()
    local st = { ub = { id = 50, status_id = 3 }, sent = {} }
    local c = fakeClient(function(body)
        local name = body:match("IrcBooks(%w+)")
        if name == "UserBook" then return 200, { data = { me = {{ user_books = { st.ub } }} } } end
        if name == "UpdateUserBook" then
            st.sent[#st.sent + 1] = body:match('"status":(%d+)')
            return 200, { data = { update_user_book = { id = 50 } } }
        end
    end)
    eq(c:setStatus(7, Hardcover.STATUS_READING), "kept")
    eq(c:setStatus(7, Hardcover.STATUS_PAUSED, true), "set")
    eq(st.sent[1], "4")
    eq(c:setStatus(7, Hardcover.STATUS_READING, true), "set")
    eq(Hardcover.STATUS_DNF, 5)
end)

test("hardcover: rating and review", function()
    local slate = Hardcover.reviewSlate("Loved it.\n\n  Second part\nsame para  \n\n\n")
    eq(#slate, 2) eq(slate[1].type, "paragraph") eq(slate[1].children[1].text, "Loved it.")
    eq(slate[2].children[1].text, "Second part\nsame para")
    eq(Hardcover.reviewSlate("   "), nil)
    local st = { ub = false, bodies = {} }
    local c = fakeClient(function(body)
        local name = body:match("IrcBooks(%w+)")
        st.bodies[#st.bodies + 1] = body
        if name == "UserBook" then return 200, { data = { me = {{ user_books = st.ub and { st.ub } or {} }} } } end
        if name == "InsertUserBook" then
            st.ub = { id = 51, status_id = 3 }
            return 200, { data = { insert_user_book = { id = 51 } } }
        end
        if name == "RateUserBook" then return 200, { data = { update_user_book = { id = 51, error = st.fail } } } end
    end)
    eq(c:setRating(7, 4.3, "Great", "2026-11-13"), "set")
    local last = st.bodies[#st.bodies]
    assert(last:find('"rating":4.5') and last:find("review_slate") and last:find('"reviewed_at":"2026%-11%-13"'), last)
    assert(st.bodies[3]:find("InsertUserBook") and st.bodies[3]:find('"status":3'), "unshelved book is added as Read")
    eq(c:setRating(7, 3, nil, "2026-11-13"), "set")
    assert(not st.bodies[#st.bodies]:find("review_slate"), "rating only")
    eq(c:setRating(7, nil, "", "x"), "unchanged")
    st.fail = "no"
    local r, err = c:setRating(7, 2)
    eq(r, nil) assert(err:find("no"))
end)

test("hardcover: new releases in followed series and by followed authors", function()
    local c = fakeClient(function(body)
        local name = body:match("IrcBooks(%w+)")
        if name == "FollowedAuthors" then
            return 200, { data = { me = {{ follows = {
                { followable_id = 3, author = { id = 3, name = "Andy Weir" } },
                { followable_id = 3, author = { id = 3, name = "Andy Weir" } },
            } }} } }
        end
        if name == "AuthorBooks" then
            assert(body:find('"since":"2025%-11%-13"'), body)
            return 200, { data = { books = {
                { id = 9, title = "New One", release_date = "2026-12-01", contributions = {{ author = { name = "Andy Weir" } }} },
            } } }
        end
    end)
    local authors = c:getFollowedAuthors()
    eq(#authors, 1) eq(authors[1].name, "Andy Weir")
    local books = c:getAuthorBooks({ 3 }, "2025-11-13")
    eq(books[1].release_date, "2026-12-01")
    local known = {}
    local g1 = {{ key = "series:1", why = "Mistborn", books = {{ id = 1, title = "A" }, { id = 2, title = "B" }} }}
    eq(#Hardcover.findNewReleases(known, g1), 0, "first sync only remembers")
    g1[1].books[3] = { id = 4, title = "C" }
    g1[2] = { key = "author:3", why = "Andy Weir", books = {{ id = 4, title = "C" }} }
    local found = Hardcover.findNewReleases(known, g1)
    eq(#found, 1) eq(found[1].title, "C") eq(found[1].why, "Mistborn")
    g1[2].books[2] = { id = 9, title = "New One" }
    found = Hardcover.findNewReleases(known, g1)
    eq(#found, 1) eq(found[1].why, "Andy Weir")
    eq(#Hardcover.findNewReleases(known, g1), 0)
end)

test("reading stats: per day, streak, dashboard text", function()
    local Stats = require("koirc/stats")
    local now = os.time{ year = 2026, month = 11, day = 13, hour = 20 }
    local days = Stats.days(now, 7)
    eq(days[1], "2026-11-13") eq(days[7], "2026-11-07")
    local sum = Stats.summarize({
        { day = "2026-11-13", title = "Dune", pages = 20, seconds = 1800 },
        { day = "2026-11-13", title = "Emma", pages = 5, seconds = 300 },
        { day = "2026-11-12", title = "Dune", pages = 30, seconds = 3700 },
        { day = "2026-11-10", title = "Dune", pages = 1, seconds = 30 },
    })
    eq(sum.pages, 56) eq(sum.active_days, 3) eq(sum.books[1].title, "Dune") eq(sum.books[1].pages, 51)
    eq(Stats.streak(sum.days, now), 2)
    eq(Stats.streak(sum.days, now + 86400), 2, "nothing yet today keeps yesterday's streak")
    eq(Stats.duration(3700), "1h 01m") eq(Stats.duration(30), "<1m") eq(Stats.duration(0), "0m")
    local text = Stats.format(sum, days, now)
    assert(text:find("Today: 25 pages · 35m"), text)
    assert(text:find("Last days: 56 pages"), text)
    assert(text:find("Days in a row: 2"), text)
    assert(text:find("• Dune — 51 p"), text)
end)

test("debug log: ring buffer, secrets hidden", function()
    local L = require("koirc/debuglog")
    L.clear()
    local old = L.MAX
    L.MAX = 3
    for i = 1, 5 do L.add("dbg", "line", i) end
    local lines = L.lines()
    eq(#lines, 3) assert(lines[1]:find("line 3$"), lines[1])
    L.MAX = old
    L.add("dbg", "ircbooks:", "> PASS hunter2")
    L.add("info", "authorization: Bearer abc.def-ghi")
    lines = L.lines()
    assert(not table.concat(lines, "\n"):find("hunter2"), "password hidden")
    assert(not table.concat(lines, "\n"):find("abc%.def"), "token hidden")
    local got = {}
    local log = L.wrap({ warn = function(...) got[#got + 1] = select("#", ...) end })
    log.warn("ircbooks:", "x")
    eq(got[1], 2) log.dbg("no real dbg is fine")
    local st = L.settingsText({ password = "p", hardcover_token = "", host = "irc", hardcover_cache = { a = 1, b = 2 } })
    assert(st:find("password = %(set%)") and st:find("hardcover_token = %(not set%)") and st:find("<2 entries>"), st)
    assert(not st:find("= p\n"), st)
    local f = io.open(tmp .. "/crash.log", "w")
    f:write("other\n12:00 ircbooks: hello\nmore\n12:01 ircbooks: > PASS secret\n")
    f:close()
    local cl = L.crashLogLines(tmp .. "/crash.log")
    eq(#cl, 2) assert(not cl[2]:find("secret"), cl[2])
    local report = L.report{ header = { "Plugin version: 1.8" }, settings = {}, crash_log = tmp .. "/crash.log" }
    assert(report:find("Plugin version: 1.8") and report:find("ircbooks: hello"), report)
end)

test("folderpicker names and creation", function()
    local FP = require("folderpicker")
    eq(FP.validateName("  Sci-Fi  "), "Sci-Fi")
    eq(select(2, FP.validateName("   ")), "empty")
    eq(select(2, FP.validateName("..")), "invalid")
    eq(select(2, FP.validateName("a/b")), "invalid")
    eq(select(2, FP.validateName("what?")), "invalid")
    eq(select(2, FP.validateName("dots.")), "invalid")
    eq(select(2, FP.validateName(string.rep("x", 300))), "too_long")
    local made, attrs = {}, { ["/books/Old"] = "directory", ["/books/note"] = "file" }
    local fs = {
        attributes = function(p) return attrs[p] end,
        mkdir = function(p)
            if p:find("Locked") then return nil, "Permission denied" end
            made[#made + 1] = p attrs[p] = "directory" return true
        end,
    }
    eq(FP.makeFolder("/books/", " New ", fs), "/books/New")
    eq(made[1], "/books/New")
    local p, err, detail = FP.makeFolder("/books", "Old", fs)
    eq(p, nil) eq(err, "exists") eq(detail, "/books/Old")
    eq(select(2, FP.makeFolder("/books", "note", fs)), "file_exists")
    local _, e2, msg = FP.makeFolder("/books", "Locked", fs)
    eq(e2, "failed") eq(msg, "Permission denied")
    eq(FP.makeFolder("/", "Top", fs), "/Top")
end)

test("results: parts, badges, bots, live count, openable", function()
    local p = results.parts({ title = "Brandon Sanderson - Mistborn 01 - The Final Empire (retail).epub" })
    eq(p.author, "Brandon Sanderson") eq(p.series, "Mistborn") eq(p.series_num, 1) eq(p.title, "The Final Empire")
    eq(results.nextInSeriesQuery(p), "Brandon Sanderson Mistborn 02")
    p = results.parts({ title = "Robert Jordan - Wheel of Time - The Eye of the World.epub" })
    eq(p.series, "Wheel of Time") eq(p.series_num, nil)
    p = results.parts({ title = "Andy Weir - The Martian.mobi" })
    eq(p.author, "Andy Weir") eq(p.series, nil) eq(p.title, "The Martian")
    p = results.parts({ title = "Leviathan Wakes (The Expanse #1).epub" })
    eq(p.series, "The Expanse") eq(p.series_num, 1)
    local list = results.parse(table.concat({
        "!a X - Book.epub ::INFO:: 1.2MB", "!b X - Book.rar ::INFO:: 3MB",
        "!a X - Book.epub.zip ::INFO:: 1MB", "!c X - Book.djvu",
    }, "\n"))
    eq(results.badge(list[1]), "EPUB · 1.2MB") eq(results.badge(list[3]), "EPUB · 1MB") eq(results.badge(list[4]), "DJVU")
    local bots = results.bots(list)
    eq(bots[1].bot, "a") eq(bots[1].count, 2) eq(#bots, 3)
    eq(#results.filterBot(list, "A"), 2) eq(#results.filterBot(list, ""), 4)
    local kept, hidden = results.filterOpenable(list, function(ext) return ext == "epub" end)
    eq(#kept, 2) eq(hidden, 2)
    local count = results.newCounter()
    eq(count("!a one\n!b tw"), 2) eq(count("o\n"), 2) eq(count("!c three\nnoise\n  !d four"), 4)
    local zcount = results.newCounter()
    eq(zcount("PK\3\4...\n!a"), 0)
end)

test("download queue: hand-picked results skip the search", function()
    local scheduled = {}
    package.loaded["ui/uimanager"].scheduleIn = function(_, _d, fn) scheduled[#scheduled + 1] = fn end
    local toasts = {}
    package.loaded["ui/widget/notification"] = { notify = function(_, t) toasts[#toasts + 1] = t end }
    package.loaded["downloadqueue"] = nil
    local Queue = require("downloadqueue")
    local log = {}
    local fetcher = {}
    function fetcher:isBusy() return false end
    function fetcher:search() log[#log + 1] = "search" return true end
    function fetcher:download(e, dir, h)
        log[#log + 1] = "get " .. e.bot
        if e.bot == "bad" then h.on_error("gone") else h.on_done(dir .. "/" .. e.title) end
        return true
    end
    local q = Queue.new{
        fetcher = function() return fetcher end,
        start_ticking = function() end,
        settings = function() return {} end,
        download_dir = function() return "/b" end,
    }
    assert(q:start({ { title = "One", entry = { bot = "ok", title = "One.epub", request = "!ok One.epub" } },
                     { title = "Two", entry = { bot = "bad", title = "Two.epub", request = "!bad Two.epub" } } }, "x"))
    local guard = 0
    while #scheduled > 0 and guard < 20 do guard = guard + 1 table.remove(scheduled, 1)() end
    eq(table.concat(log, ","), "get ok,get bad")
    eq(#q.done, 1) eq(#q.failed, 1)
    local all = table.concat(toasts, "|")
    assert(all:find("✓ Downloaded One") and all:find("✗ Could not get Two"), all)
end)

test("hardcover: search books and add to a list", function()
    local c = fakeClient(function(body)
        local name = body:match("IrcBooks(%w+)")
        if name == "Search" then
            return 200, { data = { search = { results = { hits = {
                { document = { id = "12", title = "The Martian", author_names = { "Andy Weir" }, release_year = 2011 } },
            } } } } }
        end
        if name == "InsertListBook" then
            assert(body:find('"list":4') and body:find('"book":12'), body)
            return 200, { data = { insert_list_book = { id = 99 } } }
        end
    end)
    local books = c:searchBooks("Andy Weir The Martian")
    eq(#books, 1) eq(books[1].id, 12) eq(books[1].author, "Andy Weir") eq(books[1].release_year, 2011)
    eq(c:addToList(4, 12), true)
end)


test("smart retry: offline, silent, refusing and leaving bots", function()
    local srv, f = scenario{ book = "BOOK", names = "@Search +Oatmeal Nope Leaver Silent kouser" }
    local function get(bot, opts)
        local reason, path
        assert(f:download({ bot = bot, request = "!" .. bot .. " A - B.epub", title = "A - B.epub" }, tmp .. "/books", {
            on_done = function(p) path = p end,
            on_error = function(_e, r) reason = r end,
        }, opts))
        run(f, srv, function() return reason or path end)
        return reason, path
    end
    eq(get("Gone"), "offline", "not in the channel")
    eq(f:botOnline("oatmeal"), true) eq(f:botOnline("Gone"), false)
    eq(get("Nope"), "refused")
    eq(get("Leaver"), "offline", "quit while we waited")
    eq(f:botOnline("Leaver"), false)
    eq(get("Silent", { ack_timeout = 0.3 }), "no_reply")
    local r, path = get("Oatmeal", { ack_timeout = 5 })
    eq(r, nil) eq(readFile(path), "BOOK")
    f:disconnect()
    eq(f:botOnline("Oatmeal"), nil, "unknown after disconnect")
end)

test("smart retry: tracker order", function()
    local Retry = require("koirc/retry")
    local now = 1000
    local t = Retry.new(function() return now end)
    local list = {
        { bot = "a", request = "!a x" }, { bot = "b", request = "!b x" },
        { bot = "c", request = "!c x" }, { bot = "d", request = "!d x" },
    }
    t:mark("a", "no_reply")
    t:mark("b", "refused") -- about the file, not the bot
    local online = { a = true, b = nil, c = true, d = false }
    local order = t:order(list, { ["!b x"] = true }, function(bot) return online[bot] end)
    local names = {}
    for _, e in ipairs(order) do names[#names + 1] = e.bot end
    eq(table.concat(names, ","), "c,a", "online first, failed last, offline and tried out")
    now = now + Retry.BAD_FOR + 1
    eq(t:isBad("a"), nil, "forgotten after a while")
end)

test("collections: mirror lists and series, keep own books", function()
    local CollSync = require("koirc/collsync")
    local coll = { Mine = { ["/b/own.epub"] = true }, Fantasy = { ["/b/own.epub"] = true } }
    local rc = {
        exists = function(n) return coll[n] ~= nil end,
        ensure = function(n) coll[n] = coll[n] or {} end,
        has = function(n, p) return coll[n] and coll[n][p] ~= nil end,
        add = function(n, p) coll[n][p] = true end,
        remove = function(n, p) coll[n][p] = nil end,
        isEmpty = function(n) return next(coll[n]) == nil end,
        removeCollection = function(n) coll[n] = nil end,
    }
    local files = { ["1"] = "/b/one.epub", ["2"] = "/b/two.epub", ["3"] = false, ["4"] = "/b/gone.epub" }
    local exists = function(p) return p ~= "/b/gone.epub" end
    local groups = {
        { name = "Fantasy", books = { { id = 1 }, { id = 3 }, { id = 4 } } },
        { name = "Mistborn", books = { { id = 1 }, { id = 2 } } },
        { name = "Empty", books = { { id = 3 } } },
    }
    local desired, names = CollSync.desired(groups, files, exists)
    local managed, changed = CollSync.apply(rc, desired, names, {})
    assert(changed.Fantasy and changed.Mistborn, "changed")
    eq(coll.Empty, nil, "no empty collections")
    assert(coll.Fantasy["/b/one.epub"] and coll.Fantasy["/b/own.epub"])
    assert(coll.Mistborn["/b/one.epub"] and coll.Mistborn["/b/two.epub"])
    local _m, again = CollSync.apply(rc, desired, names, managed)
    eq(again, nil, "nothing to do the second time")
    -- Book 1 left Fantasy on Hardcover; the Mistborn list was deleted.
    groups[1].books = { { id = 3 } }
    table.remove(groups, 2)
    desired, names = CollSync.desired(groups, files, exists)
    managed = CollSync.apply(rc, desired, names, managed)
    eq(coll.Fantasy["/b/one.epub"], nil, "removed from Fantasy")
    eq(coll.Fantasy["/b/own.epub"], true, "own book kept")
    eq(coll.Mistborn, nil, "deleted list's collection removed")
    eq(coll.Mine["/b/own.epub"], true, "other collections untouched")
    -- Turning it off removes only what was added.
    coll.Fantasy["/b/one.epub"] = true
    managed = CollSync.apply(rc, desired, names, managed)
    CollSync.apply(rc, {}, {}, managed)
    eq(coll.Fantasy["/b/own.epub"], true)
    -- Matched (not attached) books via a resolver, and lists kept even empty.
    local match = { [7] = "/b/matched.epub" }
    desired, names = CollSync.desired({ { name = "Thrillers", books = { { id = 7 } } }, { name = "Wish", books = {} } },
        function(b) return match[b.id] end, exists)
    CollSync.apply(rc, desired, names, {}, { Wish = true })
    eq(coll.Thrillers["/b/matched.epub"], true, "matched book added")
    assert(coll.Wish, "empty list kept as a collection")
end)

test("download history: records, search, download again", function()
    local H = require("koirc/history")
    local list = {}
    local e1 = { bot = "Oatmeal", request = "!Oatmeal Andy Weir - The Martian.epub", title = "Andy Weir - The Martian.epub", size = "1MB", ext = "epub" }
    H.add(list, H.make("/b/m.epub", nil, e1, 100))
    H.add(list, H.make("/b/d.epub", { id = 9, title = "Dune", author = "Frank Herbert" },
        { bot = "x", request = "!x Herbert - Dune.mobi", title = "Herbert - Dune.mobi", ext = "mobi" }, 200))
    H.add(list, H.make("/b/m2.epub", nil, e1, 300))
    eq(#list, 2, "same request replaces")
    eq(list[1].title, "The Martian") eq(list[1].author, "Andy Weir") eq(list[1].at, 300)
    eq(list[2].book_id, 9)
    eq(#H.search(list, "martian oatmeal"), 1)
    eq(#H.search(list, "herbert"), 1)
    eq(#H.search(list, ""), 2)
    local e = H.entry(list[1])
    eq(e.request, e1.request) eq(e.bot, "Oatmeal") eq(e.title, e1.title)
    eq(H.query(list[1]), "Andy Weir The Martian")
    H.remove(list, list[1])
    eq(#list, 1)
end)

test("backup: secrets never saved, kept on restore", function()
    local B = require("koirc/backupdata")
    local settings = { hardcover_token = "secret-token-123", password = "pw", formats = "epub",
        download_dir = "/books", hardcover_files = { ["1"] = "/b/x.epub" }, nested = { copy = "Bearer secret-token-123" } }
    local data = B.build{ settings = settings, library = { lists = { lists = {} } }, history = { { title = "x" } }, now = 5 }
    eq(data.settings.hardcover_token, nil) eq(data.settings.password, nil)
    eq(data.settings.nested.copy, nil, "token copied elsewhere is dropped")
    eq(data.settings.formats, "epub") eq(data.settings.hardcover_files["1"], "/b/x.epub")
    assert(B.isBackup(data))
    eq(B.isBackup({ settings = {} }), false)
    local cur = { hardcover_token = "mine", password = "mypw", formats = "pdf", nick = "me" }
    data.settings.hardcover_token = "evil"
    B.mergeSettings(cur, data.settings)
    eq(cur.hardcover_token, "mine") eq(cur.password, "mypw")
    eq(cur.formats, "epub") eq(cur.download_dir, "/books") eq(cur.nick, "me")
end)

os.execute("rm -rf '" .. tmp .. "'")

-------------------------------------------------------------------------------
-- v1.10
-------------------------------------------------------------------------------

test("hardcover: rate limit, Retry-After, spacing", function()
    Hardcover.resetRate()
    local t = 1000
    local slept = 0
    local answers = { 429, 200 }
    local calls = 0
    local c = Hardcover.new{
        token = "abc",
        json = { encode = jsonEncode, decode = function() error("not used") end },
        now = function() return t end,
        sleep = function(s) slept = slept + s t = t + s end,
        max_wait = 20,
        post = function()
            calls = calls + 1
            local code = table.remove(answers, 1) or 200
            if code == 429 then return 429, "", { ["retry-after"] = "7" } end
            return 200, { data = { me = {{ id = 1, username = "u", lists = {} }} } }
        end,
    }
    local res, err = c:getLists()
    assert(res, err)
    eq(calls, 2, "retried after 429")
    assert(slept >= 7, "waited Retry-After, slept " .. slept)
    -- Too long a wait: busy, and later requests fail fast without sending.
    answers = { 429 }
    Hardcover.resetRate()
    c.post = function()
        calls = calls + 1
        return 429, "", { ["retry-after"] = "120" }
    end
    calls = 0
    res, err = c:getLists()
    eq(res, nil)
    assert(Hardcover.isBusy(err), err)
    eq(calls, 1)
    res, err = c:getLists()
    assert(Hardcover.isBusy(err), err)
    eq(calls, 1, "no request while busy")
    -- After the wait, requests are spaced and capped per minute.
    t = t + 200
    Hardcover.resetRate()
    c.post = function() calls = calls + 1 return 200, { data = { me = {{ id = 1, lists = {} }} } } end
    calls, slept = 0, 0
    c.max_wait = 90
    local start = t
    for _ = 1, Hardcover.PER_MINUTE + 5 do assert(c:getLists()) end
    assert(t - start >= 60, "at most PER_MINUTE a minute, took " .. (t - start))
    -- GraphQL throttling message counts as busy too.
    Hardcover.resetRate()
    c.sleep = nil
    c.post = function() return 200, { errors = {{ message = "Throttled: too many requests" }} } end
    res, err = c:getLists()
    assert(Hardcover.isBusy(err), err)
    Hardcover.resetRate()
    eq(Hardcover.retryAfter({ ["retry-after"] = "30" }), 30)
    eq(Hardcover.retryAfter({}), nil)
end)

test("hardcover: several lists and series per request", function()
    Hardcover.resetRate()
    local c, calls = fakeClient(function(body)
        if body:find("IrcBooksListsBooks", 1, true) then
            return 200, { data = { lists = {
                { id = 5, list_books = {{ book = bookRow(1, "A", "X Y") }, { book = bookRow(2, "B", "X Y") }} },
                { id = 6, list_books = {} },
            } } }
        end
        return 200, { data = { series = {
            { id = 9, name = "Saga", book_series = {
                { position = 1, book = bookRow(3, "One", "Z") }, { position = 1.5, book = bookRow(4, "Novella", "Z") },
                { position = 2, book = bookRow(5, "Two", "Z") } } },
        } } }
    end)
    local lists = assert(c:getListBooksMany({ 5, 6 }))
    eq(#lists[5], 2) eq(#lists[6], 0) eq(lists[7], nil)
    assert(calls[1].body:find("[5,6]", 1, true) or calls[1].body:find('"ids"', 1, true))
    local series = assert(c:getSeriesBooksMany({ 9 }))
    eq(#series[9], 2, "whole positions only")
    eq(series[9][2].series, "Saga #2")
    eq(#calls, 2)
    local g = Hardcover.genres({ Genre = {{ tag = "Fantasy" }, { tag = "Adventure" }}, Mood = {{ tag = "dark" }} }, 5)
    eq(#g, 2) eq(g[1], "Fantasy")
end)

test("sync plan: skip unchanged lists, batch the rest", function()
    local SyncPlan = require("koirc/syncplan")
    local now = 100000
    local lists = { lists = {
        { id = 1, name = "A", count = 3, updated_at = "t1" },
        { id = 2, name = "B", count = 4, updated_at = "t2" },
    } }
    local series = { following = {{ id = 7, name = "S", count = 5 }}, started = {{ id = 8, name = "T", count = 2 }} }
    local fps = SyncPlan.fingerprints(lists, series)
    local old = { ["books:list:1"] = {}, ["books:list:2"] = {}, ["books:series:7"] = {}, ["books:series:8"] = {}, ["books:status:1"] = {} }
    local meta = {
        ["books:list:1"] = { at = now - 100, fp = fps["books:list:1"] },
        ["books:list:2"] = { at = now - 100, fp = "3|old" },
        ["books:series:7"] = { at = now - 2 * 86400, fp = "5" },
        ["books:series:8"] = { at = now - 2 * 86400, fp = "2" },
        ["books:status:1"] = { at = now - 10 },
    }
    local keys = { "books:list:1", "books:list:2", "books:series:7", "books:series:8", "books:status:1", "books:list:3" }
    local todo, keep = SyncPlan.plan(keys, old, meta, fps, now, { ["books:series:7"] = true })
    local t = {}
    for _, k in ipairs(todo) do t[k] = true end
    assert(not t["books:list:1"], "unchanged list kept")
    assert(t["books:list:2"], "changed list loaded")
    assert(t["books:series:7"], "followed series older than a day")
    assert(not t["books:series:8"], "other series kept for a week")
    assert(t["books:status:1"], "shelf always loaded")
    assert(t["books:list:3"], "never loaded")
    eq(#keep, 2)
    local many = {}
    for i = 1, 12 do many[#many + 1] = "books:list:" .. i end
    many[#many + 1] = "books:series:1"
    many[#many + 1] = "books:status:1"
    local b = SyncPlan.batches(many)
    eq(#b, 5, "3 list batches, 1 series, 1 shelf")
    eq(#b[1].ids, SyncPlan.LIST_BATCH)
    assert(SyncPlan.due({}, "goals", 10, now))
    assert(not SyncPlan.due({ goals = { at = now - 5 } }, "goals", 10, now))
end)

test("bot health and learned picks", function()
    local BotHealth = require("koirc/bothealth")
    local h = BotHealth.new(nil, function() return 1 end)
    for _ = 1, 5 do h:record{ bot = "Fast", ok = true, bytes = 1000000, secs = 2, wait = 5 } end
    for _ = 1, 3 do h:record{ bot = "Flaky", ok = false, reason = "no_reply" } end
    h:record{ bot = "Flaky", ok = true, bytes = 1000, secs = 10, wait = 200 }
    eq(h:record{ bot = "Fast", ok = false, reason = "refused" }, false, "refusals say nothing about the bot")
    eq(h:record{ bot = "Fast", ok = false, reason = "interrupted" }, false)
    assert(h:score("Fast") > h:score("Unknown"), "fast beats unknown")
    assert(h:score("Unknown") > h:score("Flaky"), "unknown beats flaky")
    -- Retry order: same online state, healthier bot first.
    local tracker = require("koirc/retry").new(function() return 1 end)
    tracker:setHealth(h)
    local order = tracker:order({ { bot = "Flaky", request = "a" }, { bot = "Fast", request = "b" } })
    eq(order[1].bot, "Fast")
    -- Picks: mobi picked often moves ahead of epub preferred first.
    local epub = { bot = "B", ext = "epub", title = "x.epub" }
    local mobi = { bot = "B", ext = "mobi", title = "x.mobi" }
    assert(h:rank(epub, 1, "epub") < h:rank(mobi, 2, "mobi"), "no picks yet: preference order")
    for _ = 1, 4 do h:recordPick("mobi", "B") end
    assert(h:rank(mobi, 2, "mobi") < h:rank(epub, 1, "epub"), "learned mobi")
    eq(h:rank(epub, 1000, "rar"), 1000, "archives stay last")
    local rep = h:report()
    eq(rep[1].name, "Fast")
end)

test("reading goal progress and menu trimming", function()
    local Stats = require("koirc/stats")
    local from = os.time{ year = 2026, month = 1, day = 1, hour = 0 }
    local to = os.time{ year = 2027, month = 1, day = 1, hour = 0 }
    local mid = from + math.floor((to - from) / 2)
    local g = Stats.goal(10, 24, mid, from, to)
    eq(g.pct, 42) assert(g.diff < -1.5, "behind")
    eq(Stats.bar(50, 10), "▓▓▓▓▓░░░░░")
    local lines = Stats.goalLines(Stats.goal(24, 24, mid, from, to), "2026", function(f, ...) local a = { ... } return (f:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end,
        { goal = "%1: %2/%3 %4", ahead = "+%1", behind = "-%1", on_track = "ok", done = "done", days_left = "%1 %2" })
    eq(lines[1], "2026: 24/24 100") eq(lines[3], "done")
    package.loaded.gettext = package.loaded.gettext or function(x) return x end
    local MenuPrefs = require("menuprefs")
    local v = MenuPrefs.visible({ { id = "search" }, { id = "stats" }, { id = "bots" }, { id = "settings" } }, { search = true, stats = true })
    eq(#v, 3) eq(v[1].id, "search") eq(v[2].id, "bots")
end)

test("list page turns: fast refresh, cleanup, no-op swipes, cover strips, memo", function()
    local Pager = require("koirc/pager")
    eq(Pager.turnMode(1), "fast") eq(Pager.turnMode(6), "partial") eq(Pager.turnMode(7), "fast")
    eq(Pager.turnMode(3, false), "ui") eq(Pager.turnMode(6, true, 0), "fast") eq(Pager.turnMode(4, nil, 4), "partial")
    assert(Pager.isNoop(1, 1, 1)) assert(not Pager.isNoop(1, 1, 3)) assert(not Pager.isNoop(1, 2, 2))
    eq(#Pager.uncovered(100, 200, { x = 0, y = 0, w = 100, h = 200 }), 0)
    local strips = Pager.uncovered(100, 200, { x = 0, y = 0, w = 100, h = 150 })
    eq(#strips, 1) eq(strips[1].y, 150) eq(strips[1].h, 50)
    eq(#Pager.uncovered(100, 200, nil), 1)
    local t = 0
    local m = Pager.memo(10, function() return t end)
    m:get(1).x = true
    eq(m:get(1).x, true)
    eq(m:get(2).x, nil, "new stamp")
    m:get(2).y = true t = 11
    eq(m:get(2).y, nil, "ttl")
    m:get(2).z = true m:clear()
    eq(m:get(2).z, nil, "clear")
end)

test("hardcover: indexed file lookup matches comparing every file", function()
    math.randomseed(3)
    local letters = "abcdefghiklmnoprstuvwy"
    local vocab = { "the", "of", "and", "stone", "stones", "kingdom", "kingdoms", "vengeance", "conspiracy" }
    for i = 1, 400 do
        local x = ""
        for _j = 1, math.random(4, 11) do local k = math.random(#letters) x = x .. letters:sub(k, k) end
        vocab[#vocab + 1] = x
    end
    local function title(n)
        local t = {}
        for i = 1, n do t[i] = vocab[math.random(#vocab)] end
        return table.concat(t, " ")
    end
    local files = {}
    for i = 1, 300 do
        files[i] = Hardcover.fileEntry("/b/" .. (math.random() < 0.5 and "Ann Smith" or "Bo Jones") .. " - " .. title(math.random(1, 6)) .. ".epub")
    end
    local function slow(book)
        for _i, f in ipairs(files) do if Hardcover.matches(book, f) then return f.path end end
    end
    local found = 0
    for i = 1, 400 do
        local t
        if i % 2 == 0 then
            -- Words of a real file name, sometimes with a typo or a subtitle.
            t = files[math.random(#files)].path:match(" %- (.-)%.epub$")
            if i % 6 == 0 then t = t:gsub("e", "a", 1) end
            if i % 10 == 0 then t = t .. ": " .. title(2) end
        else
            t = title(math.random(1, 6))
        end
        local book = { id = i, title = t, author = (i % 3 == 0) and "Ann Smith" or "Bo Jones" }
        local want = slow(book)
        if want then found = found + 1 end
        eq(Hardcover.findFile(book, files), want, t)
    end
    assert(found > 50, "too few matches to mean anything: " .. found)
    -- Files added later are found too.
    files[#files + 1] = Hardcover.fileEntry("/b/Jussi Adler-Olsen - The Purity of Vengeance.epub")
    eq(Hardcover.findFile({ title = "The Purity of Vengeance", author = "Jussi Adler-Olsen" }, files), files[#files].path)
end)

test("hardcover: typo distance and lookups after downloads stay exact", function()
    -- Reference edit distance (plain, no early exit).
    local function ref(a, b)
        local d = {}
        for i = 0, #a do d[i] = { [0] = i } end
        for j = 0, #b do d[0][j] = j end
        for i = 1, #a do
            for j = 1, #b do
                local c = a:sub(i, i) == b:sub(j, j) and 0 or 1
                d[i][j] = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
            end
        end
        return d[#a][#b]
    end
    math.randomseed(11)
    local letters = "abcde"
    local function rw(n) local x = "" for _ = 1, n do local k = math.random(#letters) x = x .. letters:sub(k, k) end return x end
    for _ = 1, 3000 do
        local a, b = rw(math.random(0, 9)), rw(math.random(0, 9))
        local max = math.random(1, 2)
        local want = ref(a, b)
        local got = Hardcover.distance(a, b, max)
        if want <= max then eq(got, want, a .. "/" .. b) else assert(got > max, a .. "/" .. b) end
    end
    -- Files added one by one after lookups (downloads) give the same
    -- answers as comparing every file.
    local vocab = {}
    for i = 1, 300 do vocab[i] = rw(math.random(4, 10)) end
    local function title(n) local t = {} for i = 1, n do t[i] = vocab[math.random(#vocab)] end return table.concat(t, " ") end
    local files = {}
    for i = 1, 200 do files[i] = Hardcover.fileEntry("/b/Ann Smith - " .. title(math.random(1, 5)) .. ".epub") end
    local books = {}
    for i = 1, 300 do
        local t = i % 2 == 0 and files[math.random(#files)].path:match(" %- (.-)%.epub$") or title(math.random(1, 5))
        if i % 4 == 0 then t = t:gsub("a", "e", 1) end
        books[i] = { id = i, title = t, author = "Ann Smith" }
    end
    local function slow(book)
        for _i, f in ipairs(files) do if Hardcover.matches(book, f) then return f.path end end
    end
    for round = 1, 12 do
        for _i, b in ipairs(books) do eq(Hardcover.findFile(b, files), slow(b), b.title) end
        files[#files + 1] = Hardcover.fileEntry("/b/new" .. round .. " - " .. books[round * 7].title:gsub("e", "a", 1) .. " " .. title(1) .. ".epub")
    end
end)


test("v1.11: skip folders when scanning", function()
    os.execute("mkdir -p '" .. tmp .. "/lib2/Comics/x' '" .. tmp .. "/lib2/Books' '" .. tmp .. "/lib2/PDFs'")
    writeFile(tmp .. "/lib2/Books/A.epub", "x")
    writeFile(tmp .. "/lib2/Comics/x/B.epub", "x")
    writeFile(tmp .. "/lib2/PDFs/C.pdf", "x")
    local fakeLfs = {
        dir = function(d)
            local p = io.popen("ls -1a '" .. d .. "' 2>/dev/null")
            local names = {}
            for n in p:lines() do names[#names + 1] = n end
            p:close()
            local i = 0
            return function() i = i + 1 return names[i] end
        end,
        attributes = function(path)
            local p = io.popen("test -d '" .. path .. "' && echo d || (test -f '" .. path .. "' && echo f)")
            local r = p:read("*l") p:close()
            return r == "d" and "directory" or r == "f" and "file" or nil
        end,
    }
    local function names(files)
        local out = {}
        for _, f in ipairs(files) do out[#out + 1] = f.path:match("[^/]+$") end
        table.sort(out)
        return table.concat(out, ",")
    end
    eq(Hardcover.skipper(nil), nil) eq(Hardcover.skipper({}), nil)
    eq(names(Hardcover.scan(fakeLfs, { tmp .. "/lib2" }, 4)), "A.epub,B.epub,C.pdf")
    local skip = Hardcover.skipper({ "comics", tmp .. "/lib2/PDFs/" })
    eq(names(Hardcover.scan(fakeLfs, { tmp .. "/lib2" }, 4, nil, nil, skip)), "A.epub")
    assert(not skip(tmp .. "/lib2/PDFsX", "PDFsX"), "prefix must end at a folder")
    assert(skip(tmp .. "/lib2/pdfs/inner", "inner"), "inside a skipped folder, any case")
end)

test("v1.11: scan for new books diff", function()
    local old = { { path = "/a" }, { path = "/b" } }
    local new = { { path = "/b" }, { path = "/c" }, { path = "/d" } }
    local added, removed = Hardcover.diffFiles(old, new)
    eq(table.concat(added, ","), "/c,/d") eq(table.concat(removed, ","), "/a")
    added, removed = Hardcover.diffFiles(new, new)
    eq(#added + #removed, 0)
end)

test("v1.11: collections report what changed", function()
    local CollSync = require("koirc/collsync")
    local coll = { Old = {} }
    local rc = {
        exists = function(n) return coll[n] ~= nil end,
        ensure = function(n) coll[n] = coll[n] or {} end,
        has = function(n, p) return coll[n] and coll[n][p] ~= nil end,
        add = function(n, p) coll[n][p] = true end,
        remove = function(n, p) coll[n][p] = nil end,
        isEmpty = function(n) return next(coll[n]) == nil end,
        removeCollection = function(n) coll[n] = nil end,
    }
    coll.Old["/o.epub"] = true
    local desired = { Fantasy = { "/a.epub", "/b.epub" }, Scifi = { "/c.epub" } }
    local managed, changed, details = CollSync.apply(rc, desired, { "Fantasy", "Scifi" }, { Old = { ["/o.epub"] = true } })
    assert(changed.Fantasy and changed.Old)
    eq(details.Fantasy.added, 2) eq(details.Fantasy.created, true)
    eq(details.Old.removed, 1) eq(details.Old.deleted, true)
    local words = { added = "+%1", removed = "-%1", created = "new", deleted = "gone", more = "%1 more" }
    local lines = CollSync.describe(details, { "Fantasy", "Scifi" }, 12, words)
    eq(lines[1], "• Fantasy: new, +2") eq(lines[2], "• Scifi: new, +1") eq(lines[3], "• Old: gone")
    eq(#CollSync.describe(details, { "Fantasy", "Scifi" }, 1, words), 2, "capped")
    eq(CollSync.describe(details, {}, 1, words)[2], "2 more")
    desired.Fantasy = { "/a.epub" }
    local _m, again, d2 = CollSync.apply(rc, desired, { "Fantasy", "Scifi" }, managed)
    assert(again.Fantasy) eq(d2.Fantasy.removed, 1) eq(d2.Fantasy.created, nil) eq(d2.Scifi, nil)
    local _m3, none, d3 = CollSync.apply(rc, desired, { "Fantasy", "Scifi" }, _m)
    eq(none, nil) eq(next(d3), nil)
end)

test("v1.11: download history on-device marks without rescanning", function()
    local H = require("koirc/history")
    local list = { { path = "/b/1.epub" }, { path = "/b/2.epub" }, { path = "/b/3.epub" }, {} }
    local checks = 0
    local check = function(p) checks = checks + 1 return p == "/b/2.epub" end
    local cache, on, gone = H.presence(list, { ["/b/1.epub"] = true }, check, {})
    eq(on, 2) eq(gone, 2) eq(checks, 2, "only files the scan doesn't know are looked at")
    local _c, on2 = H.presence(list, nil, check, cache)
    eq(on2, 2) eq(checks, 2, "answers are remembered")
end)

test("v1.11: wishlist daily cap and pause", function()
    local W = require("koirc/wishlist")
    local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
    eq(W.dailyCap({}), W.DEFAULT_DAILY) eq(W.dailyCap({ wishlist_daily_max = 0 }), 0)
    eq(W.left(nil, now, 3), 3)
    local st = W.addToday(nil, now, 2)
    eq(W.left(st, now, 3), 1) eq(W.left(st, now + 86400, 3), 3, "new day")
    eq(W.left(st, now, 0), math.huge, "no limit")
    local books = {}
    for i = 1, 8 do books[i] = { id = i } end
    local tried = { ["2"] = now - 10 }
    local pick = W.pick(books, { has_file = function(b) return b.id == 1 end, tried = tried, now = now,
        retry_after = 3 * 86400, limit = math.min(W.PER_RUN, W.left(st, now, 3)) })
    eq(#pick, 1) eq(pick[1].id, 3) eq(tried["3"], now)
    eq(#W.pick(books, { has_file = function() return false end, now = now, limit = 0 }), 0)
    -- The pause switch and the cap are checked in afterSync.
    local src = readFile("ircbooks.koplugin/hardcoverui.lua")
    assert(src:find("s.wishlist_paused then return end", 1, true), "pause checked")
    assert(src:find("Wishlist.left(", 1, true), "cap checked")
end)

test("v1.11: progress box updates in place", function()
    local src = readFile("ircbooks.koplugin/main.lua")
    assert(src:find("open.setText", 1, true), "showStatus reuses the open box")
    local box = readFile("ircbooks.koplugin/statusbox.lua")
    assert(box:find('return "fast"', 1, true), "quick refresh of the box only")
    assert(box:find("min_h", 1, true), "box never shrinks")
end)

test("v1.12: background downloads save in the folder picked for the run", function()
    local scheduled = {}
    package.loaded["ui/uimanager"] = {
        scheduleIn = function(_, _d, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_, fn) for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end end,
        show = function() end,
    }
    package.loaded["downloadqueue"] = nil
    local Queue = require("downloadqueue")
    local dirs = {}
    local fetcher = {}
    function fetcher:isBusy() return false end
    function fetcher:cancel() end
    function fetcher:search(_q, h) h.on_done(results.parse("!a Andy Weir - The Martian.epub ::INFO:: 1MB")) return true end
    function fetcher:download(e, dir, h) dirs[#dirs + 1] = dir h.on_done(dir .. "/" .. e.title) return true end
    local q = Queue.new{
        fetcher = function() return fetcher end, start_ticking = function() end,
        settings = function() return { preferred_formats = "epub", formats = "" } end,
        download_dir = function() return "/auto" end,
    }
    local function run() local g = 0 while #scheduled > 0 and g < 50 do g = g + 1 table.remove(scheduled, 1)() end end
    local book = { id = 1, title = "The Martian", author = "Andy Weir" }
    assert(q:start({ book }, "x", { dir = "/picked" })) run()
    assert(q:start({ book }, "x")) run()
    eq(dirs[1], "/picked") eq(dirs[2], "/auto", "default: the background folder")
    -- Every way of starting background downloads by hand asks where to save.
    for _i, f in ipairs({ "hardcoverui.lua", "hcextras.lua", "main.lua" }) do
        local src = readFile("ircbooks.koplugin/" .. f)
        for line in src:gmatch("[^\n]+") do
            if line:find("queue:start(", 1, true) or line:find("q:start(", 1, true) then
                assert(line:find("dir =", 1, true), f .. ": " .. line)
            end
        end
    end
end)

test("v1.12: moving a file keeps every record pointing at it", function()
    local R = require("koirc/relocate")
    local d, n = R.split("/mnt/us/books/A - B.epub")
    eq(d, "/mnt/us/books") eq(n, "A - B.epub")
    eq(R.cleanDir("/x/y/"), "/x/y") eq(R.cleanDir("/"), "/")
    local taken = { ["/n/A.epub"] = true, ["/n/A (2).epub"] = true }
    eq(R.target("/n/", "A.epub", function(p) return taken[p] end), "/n/A (3).epub")
    eq(R.target("/", "A.epub", function() return false end), "/A.epub")
    assert(R.sameDir("/a/b.epub", "/a/")) assert(not R.sameDir("/a/b.epub", "/a/c"))
    local files = { ["1"] = "/o/a.epub", ["2"] = false, ["3"] = "/o/b.epub" }
    eq(R.replaceValues(files, "/o/a.epub", "/n/a.epub"), 1) eq(files["1"], "/n/a.epub") eq(files["2"], false)
    local hist = { { path = "/o/a.epub" }, { path = "/o/b.epub" } }
    eq(R.history(hist, "/o/a.epub", "/n/a.epub"), 1) eq(hist[1].path, "/n/a.epub")
    local managed = { L = { ["/o/a.epub"] = true }, M = { ["/o/b.epub"] = true } }
    eq(R.managed(managed, "/o/a.epub", "/n/a.epub"), 1)
    eq(managed.L["/n/a.epub"], true) eq(managed.L["/o/a.epub"], nil)

    -- The move itself, with KOReader stubbed: a real file in a temp folder.
    local function sh(c) return os.execute(c) == 0 or os.execute(c) == true end
    local fake_lfs = { attributes = function(p, what)
        local mode
        if sh("test -d '" .. p .. "'") then mode = "directory"
        elseif sh("test -f '" .. p .. "'") then mode = "file" end
        if not mode then return nil end
        if what == "mode" then return mode end
        if what == "size" then local f = io.open(p, "rb") local sz = f:seek("end") f:close() return sz end
        return { mode = mode }
    end }
    package.loaded["libs/libkoreader-lfs"] = fake_lfs
    package.loaded["ui/widget/buttondialog"] = { new = function(_, o) return o end }
    package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o end }
    package.loaded["ui/uimanager"] = { show = function() end, close = function() end }
    package.loaded["logger"] = { warn = function() end, info = function() end, dbg = function() end }
    local updated = {}
    package.loaded["docsettings"] = { updateLocation = function(a, b) updated.sdr = a .. ">" .. b end }
    package.loaded["readhistory"] = { updateItem = function(_, a, b) updated.hist = a .. ">" .. b end }
    package.loaded["readcollection"] = { addCollection = true, updateItem = function(_, a, b) updated.coll = a .. ">" .. b end }
    local saved_hist = { list = { { path = tmp .. "/mv/a/Book.epub" } }, saves = 0 }
    package.loaded["historyui"] = { list = function() return saved_hist.list end,
        save = function() saved_hist.saves = saved_hist.saves + 1 end, renamed = function() end }
    package.loaded["storage"] = { forget = function() end }
    package.loaded["filemove"] = nil
    local FileMove = require("filemove")
    os.execute("mkdir -p '" .. tmp .. "/mv/a' '" .. tmp .. "/mv/b'")
    local old = tmp .. "/mv/a/Book.epub"
    writeFile(old, "book")
    writeFile(tmp .. "/mv/b/Book.epub", "other") -- name taken there
    local store = { collections = { L = { [old] = true } } }
    local renamed
    local plugin = {
        settings = { hardcover_files = { ["7"] = old } },
        saveSettings = function() end,
        ui = {},
        hardcover = {
            storeValue = function(_, k) return store[k] end,
            setStoreValue = function(_, k, v) store[k] = v end,
            renameFile = function(_, a, b) renamed = a .. ">" .. b end,
        },
    }
    local new = assert(FileMove.move(plugin, old, tmp .. "/mv/b/"))
    eq(new, tmp .. "/mv/b/Book (2).epub")
    eq(readFile(new), "book") assert(not sh("test -f '" .. old .. "'"), "old file gone")
    eq(plugin.settings.hardcover_files["7"], new)
    eq(saved_hist.list[1].path, new) eq(saved_hist.saves, 1)
    eq(store.collections.L[new], true)
    eq(renamed, old .. ">" .. new) eq(updated.sdr, old .. ">" .. new) eq(updated.hist, old .. ">" .. new)
    eq(FileMove.move(plugin, new, tmp .. "/mv/b"), new, "same folder: nothing to do")
    plugin.ui.document = { file = new }
    local r, err = FileMove.move(plugin, new, tmp .. "/mv/a")
    eq(r, nil) assert(err:find("open"), "the open book is not moved")
end)


-------------------------------------------------------------------------------
-- v1.13: choosing files, quality, schedule, follows, lists, bulk moves
-------------------------------------------------------------------------------

test("v1.13: file choice scores match, format, size, abridged copies and bots", function()
    local Pick = require("koirc/pick")
    local Health = require("koirc/bothealth")
    local list = results.parse(table.concat({
        "!a Andy Weir - The Martian (abridged).epub ::INFO:: 300KB",
        "!b Andy Weir - The Martian.mobi ::INFO:: 900KB",
        "!c Andy Weir - The Martian.epub ::INFO:: 9KB",
        "!d Andy Weir - The Martian.epub ::INFO:: 1MB",
        "!e Andy Weir - The Martian.epub ::INFO:: 1MB",
        "!f Andy Weir - Project Hail Mary.epub ::INFO:: 1MB",
        "!g Andy Weir - The Martian (retail).epub ::INFO:: 1.1MB",
    }, "\n"))
    local book = { title = "The Martian", author = "Andy Weir" }
    local h = Health.new({}, function() return 1000 end)
    for _i = 1, 6 do h:record({ bot = "e", ok = true, bytes = 1e6, secs = 2, wait = 5 }) end
    for _i = 1, 4 do h:record({ bot = "d", ok = false, reason = "bad_file" }) end
    local ranked, info = Pick.rank(list, { book = book, prefs = { "epub", "mobi" }, health = h,
        online = function(bot) if bot == "g" then return false end end })
    local order = {}
    for i, e in ipairs(ranked) do order[i] = e.bot end
    eq(table.concat(order, ","), "e,b,d,c,a,g", "healthy epub, mobi, then epub from a bot that sent only bad files; tiny, abridged and offline last")
    assert(Pick.explain(info[ranked[1]]):find("your 1st format"), Pick.explain(info[ranked[1]]))
    assert(Pick.summary(info[list[1]]):find("abridged"))
    assert(Pick.summary(info[list[3]]):find("only 9 KB"))
    assert(Pick.summary(info[list[7]]):find("not in the channel"))
    eq(info[list[6]], nil, "another book is left out")
    -- Leaving out offline bots, avoided bots and tried copies.
    ranked = Pick.rank(list, { book = book, prefs = { "epub" }, blocked = { e = true }, tried = { [list[4].request] = true },
        online = function(bot) if bot == "g" then return false end end, drop_offline = true })
    for _i, e in ipairs(ranked) do assert(e.bot ~= "e" and e.bot ~= "d" and e.bot ~= "g", e.bot) end
    -- A plain search: the words searched for; books on the device sink.
    ranked, info = Pick.rank(list, { query = "weir martian", prefs = { "epub" },
        owned = function(e) return e.bot == "g" and "/books/m.epub" end })
    assert(ranked[1].bot ~= "f", "Hail Mary lacks a searched word")
    eq(info[list[7]].owned, "/books/m.epub")
    assert(Pick.unsure(info[list[1]])) assert(not Pick.unsure({ match = 10.4, why = {}, warn = {} }))
    -- "The Sample" is a title, not a sample.
    eq(Pick.partialWord({ title = "Mike Smith - The Sample.epub" }, "The Sample"), nil)
    eq(Pick.partialWord({ title = "Mike Smith - Dune (Sample).epub" }, "Dune"), "sample")
end)

test("v1.13: quality check of downloaded files", function()
    local Q = require("koirc/quality")
    local pad = string.rep("x", 5000)
    eq(Q.detect("PK\3\4" .. string.rep("\0", 26) .. "mimetypeapplication/epub+zip"), "epub")
    eq(Q.detect(string.rep("\0", 60) .. "BOOKMOBI"), "mobi")
    eq(Q.detect("%PDF-1.7\n"), "pdf")
    eq(Q.detect("<!DOCTYPE html><html><body>404</body></html>"), "html")
    eq(Q.detect("<?xml version='1.0'?><FictionBook>"), "fb2")
    eq(Q.detect("Chapter 1\nIt was a dark night."), "text")
    local function chk(t) return Q.check(t) end
    eq(chk({ ext = "epub", size = 0, head = "" }).ok, false)
    eq(chk({ ext = "epub", size = 100, head = "PK\3\4" }).ok, false, "tiny")
    local r = chk({ ext = "epub", size = 6000, head = "<html><body>Error: file not found</body></html>" .. pad })
    eq(r.ok, false) assert(r.reason:find("web page"), r.reason)
    r = chk({ ext = "epub", size = 600000, head = "PK\3\4" .. pad, tail = pad })
    eq(r.ok, false) assert(r.reason:find("cut off"), r.reason)
    r = chk({ ext = "epub", size = 600000, head = "PK\3\4" .. pad, tail = pad .. "PK\5\6" .. string.rep("\0", 18) })
    eq(r.ok, true)
    r = chk({ ext = "epub", size = 600000, head = string.rep("\0", 60) .. "BOOKMOBI" .. pad, tail = pad })
    eq(r.ok, true) eq(r.fix_ext, "mobi", "a MOBI named .epub is renamed")
    r = chk({ ext = "pdf", size = 600000, head = "%PDF-1.4" .. pad, tail = pad })
    eq(r.ok, false, "PDF without %%EOF is cut off")
    eq(chk({ ext = "pdf", size = 600000, head = "%PDF-1.4" .. pad, tail = pad .. "%%EOF\n" }).ok, true)
    r = chk({ ext = "epub", size = 200000, head = "PK\3\4" .. pad, tail = "PK\5\6", listed = 2000000 })
    eq(r.ok, false) assert(r.reason:find("listed"), r.reason)
    eq(chk({ ext = "txt", size = 4000, head = "Once upon a time " .. pad }).ok, true)
    eq(chk({ ext = "mobi", size = 9000, head = "Just some text " .. pad }).ok, false, "text is not a MOBI")
    -- Bad files count against the bot and are described.
    eq(require("koirc/retry").describe("bad_file"), "sent a damaged file or not a book")
end)

test("v1.13: bad files are deleted and reported, mislabelled books renamed", function()
    os.execute("mkdir -p '" .. tmp .. "/work' '" .. tmp .. "/books2'")
    local html = "<html><body>Error 404: not found</body></html>" .. string.rep(" ", 4000)
    local srv, f = scenario{ book = html, quality = true }
    local res, err, reason, path
    f:search("sanderson mistborn", { on_done = function(r) res = r end, on_error = function(e) err = e end })
    run(f, srv, function() return res or err end)
    assert(res, err)
    local entry = { bot = "Oatmeal", request = "!Oatmeal Brandon Sanderson - Mistborn 01 - The Final Empire.epub",
        title = "Brandon Sanderson - Mistborn 01 - The Final Empire.epub", ext = "epub" }
    f:download(entry, tmp .. "/books2", { on_done = function(p) path = p end, on_error = function(e, r) err, reason = e, r end })
    os.execute("mkdir -p '" .. tmp .. "/books2'")
    run(f, srv, function() return path or reason end)
    eq(reason, "bad_file") assert(err:find("web page"), err)
    eq(io.open(tmp .. "/books2/" .. entry.title), nil, "the bad file is gone")
    f:disconnect()
    -- A MOBI sent as .epub keeps its content and gets the right name.
    local mobi = string.rep("\0", 60) .. "BOOKMOBI" .. RANDOM
    srv, f = scenario{ book = mobi, quality = true }
    res, err, reason, path = nil, nil, nil, nil
    f:search("sanderson mistborn", { on_done = function(r) res = r end, on_error = function(e) err = e end })
    run(f, srv, function() return res or err end)
    f:download(entry, tmp .. "/books2", { on_done = function(p) path = p end, on_error = function(e, r) err, reason = e, r end })
    run(f, srv, function() return path or reason end)
    assert(path, tostring(err))
    eq(path, tmp .. "/books2/Brandon Sanderson - Mistborn 01 - The Final Empire.mobi")
    eq(readFile(path), mobi)
    f:disconnect()
end)

test("v1.13: download schedule", function()
    local S = require("koirc/schedule")
    assert(S.inWindow(23, 22, 7)) assert(S.inWindow(3, 22, 7)) assert(not S.inWindow(12, 22, 7))
    assert(S.inWindow(10, 9, 17)) assert(not S.inWindow(17, 9, 17))
    local function date(h, m) return function() return { hour = h, min = m or 0, sec = 0 } end end
    eq(S.untilOpen(0, 22, 7, date(20, 30)), 5400)
    eq(S.untilOpen(0, 22, 7, date(23)), 0)
    eq(S.untilOpen(0, 1, 5, date(6)), 19 * 3600)
    local s = { queue_hours = { from = 22, to = 7 } }
    local ok, why = S.allowed(s, { now = 0, date = date(12) })
    eq(ok, false) eq(why, "hours")
    eq(S.allowed(s, { now = 0, date = date(2) }), true)
    s = { queue_wifi_only = true, queue_charging_only = true }
    ok, why = S.allowed(s, { wifi = function() return false end })
    eq(why, "wifi")
    ok, why = S.allowed(s, { wifi = function() return true end, charging = function() return false end })
    eq(why, "charging")
    eq(S.allowed(s, { wifi = function() return nil end, charging = function() return true end }), true, "unknown Wi-Fi counts as on")
    eq(S.describe({}), nil)
    eq(S.describe({ queue_hours = { from = 22, to = 7 }, queue_wifi_only = true }), "22:00–07:00, Wi-Fi already on")
end)

test("v1.13: background queue waits for the schedule, skips owned books, asks for the file", function()
    local scheduled, notes = {}, {}
    package.loaded["ui/uimanager"] = {
        scheduleIn = function(_, _d, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_, fn) for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end end,
        show = function() end,
    }
    package.loaded["ui/widget/notification"] = { notify = function(_, t) notes[#notes + 1] = t end }
    package.loaded["downloadqueue"] = nil
    local Queue = require("downloadqueue")
    local Pick = require("koirc/pick")
    local log = {}
    local fetcher = {}
    function fetcher:isBusy() return false end
    function fetcher:cancel() end
    function fetcher:search(q, h)
        log[#log + 1] = "search " .. q
        h.on_done(results.parse("!a Andy Weir - The Martian.epub ::INFO:: 1MB\n!b Andy Weir - The Martian (sample).epub ::INFO:: 1MB"))
        return true
    end
    function fetcher:download(e, dir, h) log[#log + 1] = "get " .. e.bot h.on_done(dir .. "/" .. e.title) return true end
    local allowed, asked = false, nil
    local q = Queue.new{
        fetcher = function() return fetcher end, start_ticking = function() end,
        settings = function() return { preferred_formats = "epub", formats = "" } end,
        download_dir = function() return "/auto" end,
        may_run = function() if allowed then return true end return false, "until 22:00" end,
        owned = function(book) return book.id == 2 and "/books/dune.epub" end,
        pick = function(book, list) return Pick.rank(list, { book = book, prefs = { "epub" } }) end,
        ask_pick = function(inf) return Pick.unsure(inf) end,
        choose = function(item, cands, info, done) asked = { item = item, cands = cands, done = done } end,
    }
    local function run1() local g = 0 while #scheduled > 0 and g < 20 do g = g + 1 table.remove(scheduled, 1)() end end
    assert(q:start({ { id = 1, title = "The Martian", author = "Andy Weir" }, { id = 2, title = "Dune", author = "Frank Herbert" } }, "x", { dir = "/d" }))
    table.remove(scheduled, 1)()
    eq(#log, 0, "nothing while waiting") assert(q:statusText():find("until 22:00"), q:statusText())
    assert(notes[#notes]:find("waiting"), notes[#notes])
    allowed = true
    run1()
    eq(table.concat(log, "|"), "search Andy Weir The Martian|get a", "the sample copy is not the pick")
    eq(asked, nil, "a sure pick is not asked about")
    eq(#q.done, 1) eq(#q.have, 1, "Dune was on the device")
    -- The user picks when unsure.
    log = {}
    q.env.ask_pick = function() return true end
    assert(q:start({ { id = 3, title = "The Martian", author = "Andy Weir" } }, "x", { dir = "/d" }))
    run1()
    assert(asked, "asked") eq(asked.cands[1].bot, "a")
    asked.done(asked.cands[2])
    run1()
    eq(log[#log], "get b", "the chosen file is downloaded")
    -- Started by hand with "Start now": the schedule is ignored.
    allowed, log = false, {}
    q.env.ask_pick = nil
    assert(q:start({ { id = 4, title = "The Martian", author = "Andy Weir" } }, "x", { dir = "/d", now = true }))
    run1()
    eq(log[#log], "get a")
end)

test("v1.13: followed authors", function()
    local F = require("koirc/follows")
    local s = {}
    local a, new = F.add(s, " Brandon Sanderson ")
    eq(new, true) eq(a.name, "Brandon Sanderson")
    local _b, again = F.add(s, "brandon sanderson", 42)
    eq(again, false) eq(F.find(s, "BRANDON SANDERSON").id, 42)
    F.add(s, "Martha Wells")
    eq(#F.unresolved(s), 1)
    eq(F.bestAuthor("Martha Wells", { { id = 1, name = "Martha Wellsley" }, { id = 7, name = "Martha Wells" } }).id, 7)
    eq(F.bestAuthor("Wells, Martha", { { id = 7, name = "Martha Wells" } }).id, 7)
    eq(F.bestAuthor("Martha Wells", { { id = 1, name = "Orson Welles" } }), nil)
    local merged = F.merge({ { id = 42, name = "Brandon Sanderson" }, { id = 9, name = "N. K. Jemisin" } }, s)
    eq(#merged, 2, "no doubles; Wells has no id yet")
    F.find(s, "Martha Wells").id = 7
    eq(#F.merge({}, s), 2)
    F.setAuto(s, "Brandon Sanderson", true)
    F.setAuto(s, "N. K. Jemisin", true) -- followed on Hardcover only
    eq(F.find(s, "N. K. Jemisin").mine, nil)
    eq(#F.merge({}, s), 2, "a Hardcover-only entry is not followed again")
    local tried = {}
    local books = {
        { id = 1, title = "Wind and Truth", authors = "Brandon Sanderson", release_date = "2024-12-06" },
        { id = 2, title = "Future Book", authors = "Brandon Sanderson", release_date = "2099-01-01" },
        { id = 3, title = "System Collapse", authors = "Martha Wells", release_date = "2023-11-14" },
        { id = 4, title = "Have It", authors = "N. K. Jemisin", release_year = 2020 },
    }
    local pick = F.autoPicks(books, s, { has_file = function(b) return b.id == 4 end, tried = tried, now = 5, today = "2026-11-16" })
    eq(#pick, 1) eq(pick[1].id, 1, "out, auto on, not on the device")
    eq(tried["1"], 5)
    eq(#F.autoPicks(books, s, { has_file = function() return false end, tried = tried, now = 6, today = "2026-11-16" }), 1, "Jemisin's; Sanderson's tried")
    assert(F.remove(s, "Martha Wells")) eq(F.find(s, "Martha Wells"), nil)
end)

test("v1.13: export and import book lists", function()
    local L = require("koirc/listfile")
    local stored
    local json = { encode = function(t) stored = t return "{json}" end, decode = function() return stored end }
    local text = L.encode(json, {
        want = { { id = 1, title = "Dune", author = "Frank Herbert", path = "/x" }, { title = "" } },
        series = { { id = 5, name = "Mistborn", books = { { id = 2, title = "The Final Empire", series_pos = 1 } } } },
        lists = { { id = 9, name = "Owned", books = { { id = 1, title = "Dune" }, { id = 3, title = "Emma" } } } },
        authors = { { name = "Martha Wells", id = 7 } },
        now = 0,
    })
    eq(text, "{json}")
    eq(stored.format, "ircbooks-lists") eq(#stored.want_to_read, 1) eq(stored.want_to_read[1].path, nil, "no device paths")
    stored.want_to_read[1].id = "1" -- numbers may come back as text
    local d = assert(L.parse(json, "  {...}"))
    eq(d.want_to_read[1].id, 1) eq(d.series[1].books[1].title, "The Final Empire")
    eq(#L.allBooks(d), 3, "Dune once") eq(#L.allBooks(d, "lists"), 2)
    assert(L.summary(d):find("1 Want to read · 1 series %(1 books%) · 1 lists %(2 books%) · 1 authors"), L.summary(d))
    stored = { format = "something-else" }
    local bad, err = L.parse(json, "{}")
    eq(bad, nil) assert(err:find("not a book list"))
    d = assert(L.parse(json, "# my list\nAndy Weir - The Martian\n- Dune by Frank Herbert\nEmma\n"))
    eq(#d.want_to_read, 3)
    eq(d.want_to_read[1].author, "Andy Weir") eq(d.want_to_read[1].title, "The Martian")
    eq(d.want_to_read[2].title, "Dune") eq(d.want_to_read[2].author, "Frank Herbert")
    eq(d.want_to_read[3].title, "Emma")
end)

test("v1.13: bulk moves and filing by author and series", function()
    local R = require("koirc/relocate")
    eq(R.organisedDir("/books/", "author", { author = "Andy Weir" }), "/books/Andy Weir")
    eq(R.organisedDir("/books", "author_series", { author = "B. Sanderson", series = "Mistborn #2" }), "/books/B. Sanderson/Mistborn")
    eq(R.organisedDir("/books", "series", { author = "X" }), "/books", "no series: stays at the root")
    eq(R.organisedDir("/", "author", { author = "A/B: C" }), "/A B C")
    local plan = R.plan({
        { path = "/books/Andy Weir/The Martian.epub", info = { author = "Andy Weir" } },
        { path = "/books/Dune.epub", info = { author = "Frank Herbert" } },
    }, "/books", "author")
    eq(#plan, 1, "already filed") eq(plan[1].dir, "/books/Frank Herbert")
    plan = R.plan({ { path = "/a/x.epub" }, { path = "/b/y.epub" } }, "/b/")
    eq(#plan, 1) eq(plan[1].path, "/a/x.epub")
    -- Moving several files writes the download history once.
    local saves = 0
    package.loaded["historyui"] = { list = function() return { { path = tmp .. "/bm/a/1.epub" }, { path = tmp .. "/bm/a/2.epub" } } end,
        save = function() saves = saves + 1 end, renamed = function() end }
    package.loaded["filemove"] = nil
    local FileMove = require("filemove")
    os.execute("mkdir -p '" .. tmp .. "/bm/a' '" .. tmp .. "/bm/b'")
    writeFile(tmp .. "/bm/a/1.epub", "1") writeFile(tmp .. "/bm/a/2.epub", "2")
    local plugin = { settings = {}, saveSettings = function() end, ui = {},
        hardcover = { storeValue = function() end, setStoreValue = function() end, renameFile = function() end } }
    local batch = {}
    assert(FileMove.move(plugin, tmp .. "/bm/a/1.epub", tmp .. "/bm/b", batch))
    assert(FileMove.move(plugin, tmp .. "/bm/a/2.epub", tmp .. "/bm/b", batch))
    eq(saves, 0) FileMove.finishBatch(plugin, batch) eq(saves, 1)
    eq(readFile(tmp .. "/bm/b/2.epub"), "2")
end)

test("v1.13: better format copies and format warnings", function()
    local Fm = require("koirc/formats")
    local list = results.parse("!a A - B.mobi ::INFO:: 1MB\n!b A - B.epub ::INFO:: 1MB\n!c A - B.pdf ::INFO:: 3MB")
    eq(Fm.betterCopy(list[1], list, { "epub", "mobi" }), list[2])
    eq(Fm.betterCopy(list[2], list, { "epub", "mobi" }), nil, "already the first choice")
    eq(Fm.betterCopy(list[3], { list[3] }, { "epub" }), nil, "no other copy")
    assert(Fm.warning("pdf")) eq(Fm.warning("epub"), nil)
end)

test("v1.13: new modules load and their menus build", function()
    -- Settings items are built when the menu opens: building them must not fail.
    package.loaded["ui/widget/buttondialog"] = { new = function(_, o) return o end }
    package.loaded["ui/widget/confirmbox"] = { new = function(_, o) return o end }
    package.loaded["ui/widget/inputdialog"] = { new = function(_, o) return o end }
    package.loaded["ui/network/manager"] = { isConnected = function() return true end }
    package.loaded["device"] = {}
    package.loaded["learnstore"] = { health = function() return require("koirc/bothealth").new({}) end }
    package.loaded["koirc/debuglog"] = { wrap = function(l) return l end }
    package.loaded["logger"] = { warn = function() end, info = function() end, dbg = function() end, err = function() end }
    package.loaded["hardcoverui"] = { isCharging = function() return true end }
    for _i, m in ipairs({ "picker", "scheduleprefs", "authorsui", "listsio", "bulkmove" }) do
        package.loaded[m] = nil
        assert(require(m), m)
    end
    local plugin = { settings = { queue_hours = { from = 22, to = 7 } }, saveSettings = function() end,
        fetcher = { botOnline = function() end } }
    for _i, m in ipairs({ "picker", "scheduleprefs" }) do
        local item = require(m).getSettingsItem(plugin)
        local sub = item.sub_item_table_func()
        assert(#sub > 2, m)
        if item.text_func then assert(item.text_func()) end
        for _j, it in ipairs(sub) do if it.text_func then assert(it.text_func()) end end
    end
    eq(require("scheduleprefs").getSettingsItem(plugin).text_func(), "Download schedule: 22:00–07:00")
    local Picker = require("picker")
    Picker.setBlocked(plugin, "BadBot", true)
    assert(Picker.isBlocked(plugin.settings, "badbot"))
    Picker.setBlocked(plugin, "badbot", false)
    eq(#plugin.settings.blocked_bots, 0)
end)


test("v1.13: a list of own searches downloads the best result of each into a collection", function()
    local SL = require("searchlist")
    local items = SL.parse("sanderson mistborn\n\n# note\n- Andy Weir - The Martian\nSanderson  Mistborn\n")
    eq(#items, 2, "blank, note and double left out") eq(items[2].query, "Andy Weir - The Martian") assert(items[1].is_query)
    -- The queue searches the typed text and keeps results with most words.
    local scheduled = {}
    package.loaded["ui/uimanager"] = {
        scheduleIn = function(_, _d, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_, fn) for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end end,
        show = function() end,
    }
    package.loaded["downloadqueue"] = nil
    local Queue = require("downloadqueue")
    local Pick = require("koirc/pick")
    local log, colls = {}, {}
    local fetcher = {}
    function fetcher:isBusy() return false end
    function fetcher:cancel() end
    function fetcher:search(q, h)
        log[#log + 1] = "search " .. q
        h.on_done(results.parse(table.concat({
            "!a Brandon Sanderson - Elantris.epub ::INFO:: 1MB",
            "!b Brandon Sanderson - Mistborn 01 - The Final Empire.mobi ::INFO:: 1MB",
            "!c Brandon Sanderson - Mistborn 01 - The Final Empire.epub ::INFO:: 1MB",
        }, "\n")))
        return true
    end
    function fetcher:download(e, dir, h) log[#log + 1] = "get " .. e.bot h.on_done(dir .. "/" .. e.title) return true end
    local q = Queue.new{
        fetcher = function() return fetcher end, start_ticking = function() end,
        settings = function() return { preferred_formats = "epub", formats = "" } end,
        download_dir = function() return "/auto" end,
        after_download = function(path, _book, _e, coll) colls[#colls + 1] = coll return path end,
        pick = function(book, list)
            local ranked, info = Pick.rank(list, { query = book.query, prefs = { "epub" } })
            return SL.keep(ranked, info), info
        end,
    }
    assert(q:start({ items[1] }, "x", { dir = "/d", collection = "Fantasy" }))
    local g = 0 while #scheduled > 0 and g < 20 do g = g + 1 table.remove(scheduled, 1)() end
    eq(table.concat(log, "|"), "search sanderson mistborn|get c", "the typed text is searched; Elantris lacks a word")
    eq(colls[1], "Fantasy")
    -- Adding to a collection.
    local added, written = {}, nil
    package.loaded["readcollection"] = { default_collection_name = "favorites", coll = { favorites = {}, Fantasy = {} },
        addCollection = function(self, n) self.coll[n] = {} end,
        addItem = function(self, p, n) self.coll[n][p] = { file = p } added[#added + 1] = n .. ":" .. p end,
        write = function(_, c) written = c end }
    package.loaded["ffi/util"].realpath = function(p) return p end
    package.loaded["addcoll"] = nil
    local AC = require("addcoll")
    eq(table.concat(AC.names(), ","), "favorites,Fantasy") eq(AC.label("favorites"), "Favorites")
    eq(AC.add({ "/b/1.epub", "/b/2.epub" }, "Fantasy"), 2) eq(written.Fantasy, true)
    eq(AC.add("/b/1.epub", "Fantasy"), 0, "already in it")
    eq(AC.add("/b/3.epub", "New one"), 1) assert(AC.exists("New one"))
    eq(AC.exists("Gone"), false)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
