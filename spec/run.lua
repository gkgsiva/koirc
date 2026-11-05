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
        table.insert(srv.dccs, { listener = l, content = content, sent = 0, acks = 0 })
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
                    send(":srv 366 " .. self.nick .. " " .. m.params[1] .. " :End of /NAMES list.")
                elseif m.command == "PRIVMSG" and m.params[1] == "#ebooks" then
                    local text = m.params[2]
                    local q = text:match("^@search (.*)$")
                    if q == "nothing" then
                        send(":Search!s@h NOTICE " .. self.nick .. " :Sorry, your search for \"nothing\" returned no matches.")
                    elseif q then
                        send(":Search!s@h NOTICE " .. self.nick .. " :Your search for \"" .. q .. "\" has been accepted. Searching...")
                        offer("Search", "SearchOok_results_for_" .. q:gsub(" ", "_") .. ".txt.zip", opts.results_zip)
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
                if d.sent < #d.content then
                    local chunk = d.content:sub(d.sent + 1, d.sent + 4096)
                    local last, _, part = d.conn:send(chunk)
                    d.sent = d.sent + (last or part or 0)
                end
                local a, _, p = d.conn:receive(4)
                if a and #a == 4 then d.acks = d.acks + 1 end
                if d.sent >= #d.content then
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
    local srv = newServer{ results_zip = readFile(tmp .. "/res.zip"), book = opts.book, nick_taken = opts.nick_taken }
    local f = Fetcher.new{
        socket = socket,
        config = { host = "127.0.0.1", port = srv.port, nick = "kouser", channel = "#ebooks", search_cmd = "@search" },
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
        unschedule = function(_, fn) for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end end,
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

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
