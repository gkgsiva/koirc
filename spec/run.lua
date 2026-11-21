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
        eq(#readFile(c.base .. "/Sci_Fi_ Classics/Dune.epub"), 5000)
        eq(#readFile(c.base .. "/Sci_Fi_ Classics/Shared.epub"), 2000)
        eq(#readFile(c.base .. "/Reads/Shared.epub"), 2000, "copy in second folder")
        eq(#readFile(c.base .. "/Reads/Emma & Co.epub"), 3000, "url-decoded name, no length in feed")
        eq(readFile(c.base .. "/Reads/Broken.epub.part"), nil)

        -- second run: nothing new except retrying the failed one
        r = sync.run(c)
        eq(r.downloaded, 0) eq(r.skipped, 3) eq(#r.failed, 1)

        -- deleted locally -> fetched again; wrong auth -> clear error
        os.remove(c.base .. "/Sci_Fi_ Classics/Dune.epub")
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
        writeFile(rc.base .. "/Sci_Fi_ Classics/Dune.epub.part", string.rep("D", 1200))
        r = sync.run(rc)
        eq(#readFile(rc.base .. "/Sci_Fi_ Classics/Dune.epub"), 5000, "resumed file complete")
        eq(readFile(rc.base .. "/Sci_Fi_ Classics/Dune.epub"), string.rep("D", 5000))
        eq(readFile(rc.base .. "/Sci_Fi_ Classics/Dune.epub.part"), nil)

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

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
