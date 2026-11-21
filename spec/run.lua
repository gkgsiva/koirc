-- Specs: luajit spec/run.lua  (needs LuaSocket and python3 for the fake server)
package.path = "./librarysync.koplugin/?.lua;" .. package.path
local xml = require("librarysync/xml")
local util = require("librarysync/util")
local sync = require("librarysync/sync")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function readFile(p) local f = io.open(p, "rb") if not f then return nil end local d = f:read("*a") f:close() return d end
local function writeFile(p, d) local f = assert(io.open(p, "wb")) f:write(d) f:close() end

local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/ls-spec-" .. os.time() .. math.random(1e6)
os.execute("mkdir -p '" .. tmp .. "'")

test("xml parse: entries, escapes, links", function()
    local f = xml.parse([[<feed><title>Hi &amp; bye</title><link rel="next" href="/a?x=1&amp;page=2"/>
      <entry><title>A &lt;b&gt;</title><id>i</id><link rel="subsection" href="/opds/folders/3" type="t"/></entry></feed>]])
    eq(f.title, "Hi & bye") eq(#f.entries, 1) eq(f.entries[1].title, "A <b>")
    eq(xml.link(f, "next").href, "/a?x=1&page=2")
    eq(xml.link(f.entries[1], "subsection").href, "/opds/folders/3")
end)

test("xml: numeric entities become UTF-8, also when escaped twice", function()
    eq(xml.unescape("Don&#39;t &#233;t&#xE9; &#x1F600;"), "Don't \195\169t\195\169 \240\159\152\128")
    eq(xml.unescape("Rock &amp;#39;n&amp;#39; &amp;amp; roll"), "Rock 'n' &amp; roll")
    eq(xml.unescape("&#0x;"), "&#0x;")
end)

test("xml: a book's Library folders come from its categories", function()
    local f = xml.parse([[<feed><entry><title>t</title><category term="Dune" label="Series: Dune #1"/>
      <category term="Sci-Fi" label="Sci-Fi"/><category term="To read" label="To read"/>
      <link rel="http://opds-spec.org/acquisition" href="/opds/files/7/t.epub"/></entry></feed>]])
    local fs = xml.folders(f.entries[1])
    eq(#fs, 2) eq(fs[1], "Sci-Fi") eq(fs[2], "To read")
    local file = sync.book_files({}, "http://h/opds/recent", f.entries[1])[1]
    eq(file.folders[2], "To read")
    -- found locally in its folder, from any view
    local c = { base = tmp .. "/find" }
    os.execute("mkdir -p '" .. c.base .. "/To read'")
    eq(sync.find_local(c, file), nil)
    writeFile(c.base .. "/To read/" .. file.name, "x")
    eq(sync.find_local(c, file), c.base .. "/To read/" .. file.name)
    eq(sync.dest(c, nil, file), c.base .. "/" .. file.name, "no folder: straight into the base")
end)

test("series: label parsing and file names", function()
    local f = xml.parse([[<feed><entry><title>t</title><category term="x" label="Series: The Wheel #2.5"/></entry>
      <entry><title>u</title><category term="x" label="Series: Solo"/></entry>
      <entry><title>v</title><calibre:series>Cal</calibre:series><calibre:series_index>4.0</calibre:series_index></entry></feed>]])
    local n, i = xml.series(f.entries[1]) eq(n, "The Wheel") eq(i, "2.5")
    n, i = xml.series(f.entries[2]) eq(n, "Solo") eq(i, nil)
    n, i = xml.series(f.entries[3]) eq(n, "Cal") eq(i, "4.0")
    f = xml.parse([[<feed><entry><title>t</title><category term="x" label="Series: Old #9"/>
      <calibre:series>New</calibre:series><calibre:series_index>3.0</calibre:series_index></entry></feed>]])
    n, i = xml.series(f.entries[1]) eq(n, "New", "calibre wins") eq(i, "3.0")
    eq(sync.series_name("Dune.epub", "Dune Saga", "1"), "Dune Saga #1 - Dune.epub")
    eq(sync.series_name("Cal #4 - x.epub", "Cal", "4.0"), "Cal #4 - x.epub")
    eq(sync.series_name("x.epub", "Cal", "4.0"), "Cal #4 - x.epub")
    eq(sync.series_name("x.epub", nil, nil), "x.epub")
end)

test("book_files: name, size, series, key", function()
    local f = xml.parse([[<feed><entry><title>Dune</title><calibre:series>Dune Saga</calibre:series><calibre:series_index>2.0</calibre:series_index>
      <link rel="http://opds-spec.org/acquisition" href="/opds/files/7/Dune%20One.epub" length="1234"/></entry></feed>]])
    local files = sync.book_files({ server = "http://h" }, "http://h/opds/folders/1", f.entries[1])
    eq(#files, 1) eq(files[1].key, "dl7") eq(files[1].size, 1234) eq(files[1].ext, "epub")
    eq(files[1].name, "Dune Saga #2 - Dune One.epub") eq(files[1].url, "http://h/opds/files/7/Dune%20One.epub")
end)

test("util: names, urls", function()
    eq(util.safe_name("a/b:c?.epub"), "a_b_c_.epub")
    eq(util.safe_name("  ..hidden. "), "hidden")
    eq(util.safe_name("", "x"), "x")
    eq(util.normalize_server("example.com/opds/"), "https://example.com")
    eq(util.normalize_server("http://h:8080/"), "http://h:8080")
    eq(util.resolve("http://h:1/opds/folders", "/opds/x"), "http://h:1/opds/x")
    eq(util.resolve("http://h:1/opds/folders", "3"), "http://h:1/opds/3")
    eq(util.url_decode("Emma%20%26%20Co.epub"), "Emma & Co.epub")
end)

test("util: state tables keep lists and numbers", function()
    local p = tmp .. "/t.lua"
    util.save_table(p, { failed = { { name = "a\nb", error = "x" } }, n = 1.5, files = { dl1 = { ["/a/b"] = 3 } } })
    local t = util.load_table(p)
    eq(#t.failed, 1) eq(t.failed[1].name, "a\nb") eq(t.n, 1.5) eq(t.files.dl1["/a/b"], 3)
end)

test("plan: shared book goes into both folders, names unique", function()
    local items = sync.plan({
        { name = "A", files = { { key = "dl1", name = "x.epub", url = "u1" }, { key = "dl2", name = "x.epub", url = "u2" } } },
        { name = "B", files = { { key = "dl1", name = "x.epub", url = "u1" } } },
    }, "/base")
    eq(#items, 2)
    eq(#items[1].dests, 2) eq(items[1].dests[1], "/base/A/x.epub") eq(items[1].dests[2], "/base/B/x.epub")
    eq(items[2].dests[1], "/base/A/x (2).epub")
end)

-- Real HTTP against the fake server.
local function start(port, mode)
    os.execute(string.format("python3 -I spec/server.py %d %s >/dev/null 2>&1 &", port, mode or ""))
    local socket = require("socket")
    for _ = 1, 50 do
        local c = socket.tcp()
        if c:connect("127.0.0.1", port) then c:close() return end
        socket.sleep(0.1)
    end
    error("server did not start")
end
local function stop(port) os.execute("pkill -f 'spec/server.py " .. port .. "'") end

local function cfg(port, name)
    return { server = "http://127.0.0.1:" .. port, auth = "basic", username = "me", password = "pw",
             base = tmp .. "/" .. name .. "/Library", state_path = tmp .. "/" .. name .. ".state" }
end

local function scenario(port, mode)
    start(port, mode)
    local ok, err = pcall(function()
        local c = cfg(port, "s" .. port)
        local r = sync.run(c)
        eq(r.total, 4) eq(r.downloaded, 3, "downloaded") eq(#r.failed, 1)
        eq(r.failed[1].name, "Broken.epub")
        eq(#readFile(c.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"), 5000)
        eq(#readFile(c.base .. "/Sci_Fi_ Classics/Shared.epub"), 2000)
        eq(#readFile(c.base .. "/Reads/Shared.epub"), 2000, "copy in second folder")
        eq(#readFile(c.base .. "/Reads/Emma & Co.epub"), 3000, "url-decoded name, no length in feed")
        eq(readFile(c.base .. "/Reads/Broken.epub.part"), nil)

        -- second run: nothing new except retrying the failed one
        r = sync.run(c)
        eq(r.downloaded, 0) eq(r.skipped, 3) eq(#r.failed, 1)

        -- deleted locally -> fetched again; wrong auth -> clear error
        os.remove(c.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub")
        r = sync.run(c)
        eq(r.downloaded, 1)
        local bad = cfg(port, "bad" .. port) bad.password = "nope"
        r = sync.run(bad)
        assert(r.error and r.error:find("login refused"), tostring(r.error))
        local tok = cfg(port, "tok" .. port) tok.auth = "bearer" tok.token = "tok"
        eq(sync.run(tok).downloaded, 3, "bearer token works")

        -- resume from a partial file
        local rc = cfg(port, "resume" .. port)
        os.execute("mkdir -p '" .. rc.base .. "/Sci_Fi_ Classics'")
        writeFile(rc.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub.part", string.rep("D", 1200))
        r = sync.run(rc)
        eq(#readFile(rc.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"), 5000, "resumed file complete")
        eq(readFile(rc.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"), string.rep("D", 5000))
        eq(readFile(rc.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub.part"), nil)

        -- cancel keeps going state sane
        local cc = cfg(port, "cancel" .. port)
        local n = 0
        cc.progress = function() n = n + 1 return n < 3 end
        r = sync.run(cc)
        assert(r.cancelled, "cancelled")
    end)
    stop(port)
    if not ok then error(err, 0) end
end
test("sync against a server without Range support", function() scenario(18741) end)
test("sync against a server with Range support", function() scenario(18742, "range") end)

local function only_folder(port)
    start(port)
    local ok, err = pcall(function()
        local c = cfg(port, "only")
        c.only = { url = c.server .. "/opds/folders/11", name = "Reads" }
        local r = sync.run(c)
        eq(r.total, 3) -- Emma, Shared, Broken
        eq(readFile(c.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"), nil, "other folder untouched")
        local file = sync.book_files(c, c.server, { title = "x", links = { { rel = "http://opds-spec.org/acquisition", href = "/opds/files/3/Shared.epub" } } })[1]
        c.transport, c.headers = require("librarysync/http").get, require("librarysync/http").auth_headers(c)
        local path = assert(sync.download_one(c, "Reads", file))
        eq(#readFile(path), 2000)
        local _, have = sync.local_path(c, "Reads", file)
        eq(have, true)
    end)
    stop(port)
    if not ok then error(err, 0) end
end
test("sync one folder, download one book", function() only_folder(18743) end)

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
