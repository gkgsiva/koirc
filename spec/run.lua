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

test("cleanup: only tracked files the server no longer has there", function()
    local c = { base = tmp .. "/clean" }
    os.execute("mkdir -p '" .. c.base .. "/A' '" .. c.base .. "/B'")
    local keep, moved, gone, mine = c.base .. "/A/k.epub", c.base .. "/B/k.epub", c.base .. "/A/g.epub", c.base .. "/A/mine.epub"
    for _, p in ipairs({ keep, moved, gone, mine }) do writeFile(p, "x") end
    local cat = { complete = true, books = { { folders = { "A" }, files = { { key = "dl1", name = "k.epub" } } } } }
    local state = { files = { dl1 = { [keep] = 1, [moved] = 1 }, dl2 = { [gone] = 1 } } }
    eq(sync.cleanup_candidates(c, { books = {} }, state), nil, "needs a complete catalog")
    local list = sync.cleanup_candidates(c, cat, state)
    eq(#list, 2) eq(list[1], gone) eq(list[2], moved)
    c.state_path = tmp .. "/clean.state"
    util.save_table(c.state_path, state)
    eq(sync.cleanup(c, list), 2)
    eq(readFile(gone), nil) eq(readFile(moved), nil) eq(readFile(keep), "x") eq(readFile(mine), "x")
    local st = util.load_table(c.state_path)
    eq(st.files.dl2, nil) eq(st.files.dl1[keep], 1) eq(st.files.dl1[moved], nil)
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
        local tr, snaps = nil, 0
        c.progress = function(_t, _a, _b, t) tr = t snaps = snaps + 1 return true end
        local r = sync.run(c)
        eq(r.total, 4) eq(r.downloaded, 3, "downloaded") eq(#r.failed, 1)
        assert(tr and snaps > 0, "progress gets the tracker")
        eq(tr.books_total, 4, "books planned") eq(tr.books_done, 3, "books done") eq(tr.failed, 1, "books failed")
        eq(r.bytes, 10000, "bytes downloaded")
        local snap = tr:snapshot()
        eq(require("librarysync/progress").pending(snap), 0, "nothing left")
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

local function extras(port)
    start(port)
    local ok, err = pcall(function()
        -- unticked folder: listed in the catalog, not downloaded
        local c = cfg(port, "skip")
        c.skip_folders = { Reads = true }
        c.catalog_path = tmp .. "/skip.cat"
        c.summaries_path = tmp .. "/skip.sum"
        c.positions_path = tmp .. "/skip.pos"
        util.save_table(c.positions_path, { dl2 = { percent = 0.42, at = 1700000000, tz = -330 }, odd = { percent = 1 } })
        local r = sync.run(c)
        eq(r.total, 2, "only Sci/Fi files") eq(r.positions, 2)
        eq(readFile(c.base .. "/Reads/Emma & Co.epub"), nil, "unticked folder not downloaded")
        local cat = util.load_table(c.catalog_path)
        eq(#cat.folders, 2) eq(#cat.books, 4) assert(cat.complete)
        eq(util.load_table(c.summaries_path)["urn:b1"], "About Dune.epub")
        eq(next(util.load_table(c.positions_path)), nil, "sent positions removed")
        local body = {}
        require("socket.http").request{ url = c.server .. "/test/positions", headers = { Authorization = "Bearer tok" }, sink = require("ltn12").sink.table(body) }
        body = table.concat(body)
        assert(body:find('^2 {"percent": 0.4200, "at": 1700000000, "tz": %-330}'), body)

        -- quick sync: nothing new; then a new book is added to Reads
        c.skip_folders = nil
        c.quick = true
        r = sync.run(c)
        assert(r.quick, "quick mode used") eq(r.new_books, 0)
        local headers = { Authorization = "Bearer tok" }
        require("socket.http").request{ url = c.server .. "/test/add", headers = headers }
        r = sync.run(c)
        eq(r.new_books, 1) eq(r.downloaded, 1)
        eq(#readFile(c.base .. "/Reads/New.epub"), 1500, "new book downloaded into its folder")
        cat = util.load_table(c.catalog_path)
        eq(#cat.books, 5, "catalog merged") eq(cat.newest, "2026-11-06T00:00:00Z")
        c.quick = nil

        -- storage guard: pauses before downloading, keeps state sane
        local g = cfg(port, "guard")
        g.free_space = function() return 150 * 1048576 end
        g.min_free = 200 * 1048576
        r = sync.run(g)
        assert(r.storage_full and r.error:find("storage nearly full"), tostring(r.error))
        eq(r.downloaded, 0)
        g.min_free = 100 * 1048576
        r = sync.run(g)
        assert(not r.storage_full) assert(r.downloaded > 0)

        -- books finished in KOReader are queued as 100% by collect_finished
        c.collect_finished = function(state)
            util.save_table(c.positions_path, { dl3 = { percent = 1, at = 1700000100, tz = 0 } })
        end
        r = sync.run(c)
        eq(r.positions, 1)
    end)
    stop(port)
    if not ok then error(err, 0) end
end
test("skip folders, catalog, summaries, reading progress", function() extras(18744) end)

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

test("util: iso time, json fields", function()
    eq(util.iso_time("2026-11-22T14:05:00Z"), 1795356300)
    eq(util.iso_time("x"), nil)
    eq(util.json_number('{"percent": 0.25, "updated_at": 17.5}', "updated_at"), 17.5)
    eq(util.json_number('{"percent": 0.25}', "nope"), nil)
end)

test("folder rules: unread and newest N", function()
    local function bk(id, added, progress)
        return { id = id, title = id, folders = { "F" }, added = added, progress = progress,
                 files = { { key = "dl" .. id, name = id .. ".epub" } } }
    end
    local cat = { books = { bk("1", "2026-01-01", 0), bk("2", "2026-03-01", 1), bk("3", "2026-02-01", 0.3),
                            { id = "4", folders = { "G" }, files = { { key = "dl4" } } } } }
    local a = sync.rule_sets({ F = "unread" }, cat)
    assert(a.F.dl1 and a.F.dl3 and not a.F.dl2, "finished book left out") eq(a.G, nil)
    local over
    a, over = sync.rule_sets({ F = 2 }, cat)
    assert(a.F.dl2 and a.F.dl3 and not a.F.dl1, "newest two")
    eq(#over.F, 1) eq(over.F[1].file.key, "dl1")
    local folders = { { name = "F", files = { { key = "dl1" }, { key = "dl2" } } }, { name = "G", files = { { key = "dl4" } } } }
    sync.apply_rules(folders, a)
    eq(#folders[1].files, 1) eq(folders[1].files[1].key, "dl2") eq(#folders[2].files, 1)
end)

local function features(port)
    start(port, "range")
    local ok, err = pcall(function()
        local c = cfg(port, "feat")
        c.catalog_path, c.plan_path = tmp .. "/feat.cat", tmp .. "/feat.plan"
        c.remote_path, c.log_path, c.queue_path = tmp .. "/feat.remote", tmp .. "/feat.log", tmp .. "/feat.queue"
        c.positions_path = tmp .. "/feat.pos"
        -- preview: 3 books to fetch >= 2 -> stops before downloading, plan saved
        c.preview_min = 2
        local r = sync.run(c)
        assert(r.preview, "preview asked") eq(r.preview_count, 4) eq(r.downloaded, 0)
        local plan = util.load_table(c.plan_path)
        eq(#plan.items, 4)
        eq(util.load_table(c.log_path), nil, "no log line for a preview")
        local cat = util.load_table(c.catalog_path)
        eq(cat.folders[1].kind, "series") eq(cat.folders[2].kind, "list")
        local emma
        for _, b in ipairs(cat.books) do if b.id == "urn:b2" then emma = b end end
        eq(emma.progress, 0.5) eq(emma.last_read, util.iso_time("2026-11-20T10:00:00Z"))
        -- the reviewed plan: Shared unticked (and remembered), the rest downloaded
        sync.update_state(c, function(st) st.declined = { dl3 = true } end)
        local rc = {}
        for k, v in pairs(c) do rc[k] = v end
        rc.use_plan, rc.exclude, rc.preview_min = true, { dl3 = true }, nil
        r = sync.run(rc)
        eq(r.downloaded, 2) eq(#r.failed, 1) eq(r.kind, "reviewed")
        eq(readFile(c.base .. "/Reads/Shared.epub"), nil, "unticked one not fetched")
        local log = util.load_table(c.log_path)
        eq(#log, 1) eq(#log[1].added, 2) eq(log[1].failed[1].name, "Broken.epub")
        local st = util.load_table(c.state_path)
        eq(st.failed.dl4.tries, 1, "failure remembered for a retry") eq(next(st.pending), nil)
        -- retry: only the failed one (and nothing else is crawled)
        rc.retry, rc.exclude = true, nil
        r = sync.run(rc)
        eq(r.total, 1) eq(r.kind, "retry")
        eq(util.load_table(c.state_path).failed.dl4.tries, 2)
        -- progress pulled at the next sync: Emma was read on another device
        c.preview_min = nil
        r = sync.run(c)
        eq(r.declined, 1, "declined stays out")
        local remote = util.load_table(c.remote_path)
        eq(remote.dl2.percent, 0.5) eq(remote.dl2.at, 1795600800)
        eq(r.pulled, 1)
        r = sync.run(c)
        eq(r.pulled, 0, "not asked again until read again")
        -- read later: queued while offline, downloaded at the next sync even when declined
        local shared = { key = "dl3", name = "Shared.epub", url = c.server .. "/opds/files/3/Shared.epub", size = 2000 }
        sync.queue_add(c, "Reads", shared, "Shared")
        r = sync.run(c)
        eq(#readFile(c.base .. "/Reads/Shared.epub"), 2000, "queued book downloaded")
        eq(next(util.load_table(c.queue_path)), nil, "queue emptied")
        -- folder rule newest 1: older books past it are offered for removal (Reads: Emma was started)
        c.folder_rules = { ["Sci/Fi: Classics"] = 1, Reads = 1 }
        c.preview_min = 50
        r = sync.run(c)
        plan = util.load_table(c.plan_path)
        assert(r.preview and #plan.removals >= 1, "removal needs review")
        local names = {}
        for _, x in ipairs(plan.removals) do names[x.name] = x.why end
        eq(names["Dune Saga #1 - Dune.epub"], "old", "never-started book past the newest 1")
        eq(names["Emma & Co.epub"], nil, "a started book is kept")
        rc.retry, rc.exclude, rc.remove = nil, {}, plan.removals
        r = sync.run(rc)
        eq(readFile(c.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"), nil, "removed after review")
        eq(r.removed[1], "Dune Saga #1 - Dune.epub")
        assert(readFile(c.base .. "/Reads/Emma & Co.epub"), "started book kept")
        eq(#util.load_table(c.log_path), 6)
    end)
    stop(port)
    if not ok then error(err, 0) end
end
test("preview, retry, sync log, progress pull, read later, folder rules", function() features(18745) end)

test("collections: shelves and series mirrored, only ours removed", function()
    local coll = require("librarysync/collections")
    local c = { base = tmp .. "/coll", catalog_path = tmp .. "/coll.cat", state_path = tmp .. "/coll.state" }
    os.execute("mkdir -p '" .. c.base .. "/To read' '" .. c.base .. "/Dune'")
    writeFile(c.base .. "/To read/a.epub", "a") writeFile(c.base .. "/Dune/d1.epub", "d") writeFile(c.base .. "/Dune/d2.epub", "e")
    util.save_table(c.catalog_path, {
        folders = { { name = "To read", kind = "list" }, { name = "Dune", kind = "series" } },
        books = {
            { id = "a", title = "A", folders = { "To read" }, files = { { key = "dl1", name = "a.epub" } } },
            { id = "d2", title = "Two", series = "Dune", number = "2", folders = { "Dune" }, files = { { key = "dl3", name = "d2.epub" } } },
            { id = "d1", title = "One", series = "Dune", number = "1", folders = { "Dune", "To read" }, files = { { key = "dl2", name = "d1.epub" } } },
            { id = "x", title = "Not here", folders = { "To read" }, files = { { key = "dl9", name = "x.epub" } } },
        } })
    util.save_table(c.state_path, { files = { dl1 = { [c.base .. "/To read/a.epub"] = 1 },
        dl2 = { [c.base .. "/Dune/d1.epub"] = 1 }, dl3 = { [c.base .. "/Dune/d2.epub"] = 1 } } })
    local colls = { Mine = { ["/own.epub"] = true } }
    local rc = {
        exists = function(n) return colls[n] ~= nil end, ensure = function(n) colls[n] = colls[n] or {} end,
        has = function(n, p) return colls[n] and colls[n][p] ~= nil end,
        add = function(n, p) colls[n][p] = true end, remove = function(n, p) colls[n][p] = nil end,
        isEmpty = function(n) return next(colls[n] or {}) == nil end, removeCollection = function(n) colls[n] = nil end,
    }
    local mp = tmp .. "/coll.managed"
    local n = coll.mirror(c, "both", mp, rc)
    eq(n, 2)
    assert(colls["To read"][c.base .. "/To read/a.epub"], "shelf book")
    assert(colls["To read"][c.base .. "/Dune/d1.epub"], "shelf book in another folder")
    assert(colls.Dune[c.base .. "/Dune/d1.epub"] and colls.Dune[c.base .. "/Dune/d2.epub"], "series")
    -- you add a book yourself; then shelves only: the series collection goes, yours stays
    colls.Dune["/mine.epub"] = true
    n = coll.mirror(c, "shelves", mp, rc)
    eq(n, 1) assert(colls.Dune and colls.Dune["/mine.epub"] and not colls.Dune[c.base .. "/Dune/d1.epub"])
    eq(coll.mirror(c, "shelves", mp, rc), 0, "nothing changes the second time")
    coll.mirror(c, "off", mp, rc)
    eq(colls["To read"], nil) assert(colls.Mine, "own collection untouched")
    local groups = coll.groups(util.load_table(c.catalog_path), "series")
    eq(groups[1].books[1].title, "One", "series in order")
end)

os.execute("rm -rf '" .. tmp .. "'")

-- KOReader's book data, in memory: path -> settings table (summary, annotations, ...)
local SIDE, CUSTOM, COVERS = {}, {}, {}
package.preload["docsettings"] = function()
    local DS = {}
    function DS:findSidecarFile(p) return SIDE[p] and (p .. ".sdr/metadata.lua") or nil end
    function DS:hasSidecarFile(p) return SIDE[p] ~= nil end
    function DS:open(p)
        local d = SIDE[p] or {}
        SIDE[p] = d
        return { readSetting = function(_, k) return d[k] end, saveSetting = function(_, k, v) d[k] = v end, flush = function() end }
    end
    function DS.openSettingsFile()
        local o = { data = {} }
        function o:readSetting(k) return self.data[k] end
        function o:saveSetting(k, v) self.data[k] = v end
        function o:flushCustomMetadata(path) CUSTOM[path] = self.data return true end
        return o
    end
    function DS:findCustomMetadataFile() return nil end
    function DS:flushCustomCover(path, img) COVERS[path] = readFile(img) return true end
    return DS
end
local ex = require("librarysync/extras")

local function calls(c)
    local body = {}
    require("socket.http").request{ url = c.server .. "/test/calls", headers = { Authorization = "Bearer tok" }, sink = require("ltn12").sink.table(body) }
    local out = {}
    for line in table.concat(body):gmatch("[^\n]+") do out[#out + 1] = line end
    return out
end

local function v23(port)
    start(port, "v23")
    local ok, err = pcall(function()
        local c = cfg(port, "v23")
        local P = function(n) return tmp .. "/v23." .. n end
        c.catalog_path, c.summaries_path, c.positions_path = P("cat"), P("sum"), P("pos")
        c.status_path, c.notes_path, c.remote_status_path = P("status"), P("notes"), P("rstatus")
        c.removed_path, c.queue_path, c.log_path = P("removed"), P("queue"), P("log")
        c.refresh_meta = true
        local dune, emma = c.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub", c.base .. "/Reads/Emma & Co.epub"
        local shared1, shared2 = c.base .. "/Sci_Fi_ Classics/Shared.epub", c.base .. "/Reads/Shared.epub"

        -- format preference: Shared is offered as PDF (first) and EPUB; only the EPUB is taken
        local r = sync.run(c)
        eq(r.downloaded, 3) eq(readFile(c.base .. "/Reads/Shared.pdf"), nil, "no PDF")
        eq(#readFile(shared2), 2000)
        -- status pulled from the Library: Dune is Read, Emma is Reading
        eq(r.status_pulled, 3)
        local rs = util.load_table(c.remote_status_path)
        eq(rs.dl1.status, "read") eq(rs.dl2.status, "reading")
        -- this account's own status and rating win over the Hardcover shelf
        eq(rs.dl3.status, "dnf") eq(rs.dl3.rating, 3.5)
        eq(sync.run(c).status_pulled, 0, "only new statuses")
        -- covers and book info written as KOReader custom metadata, without a new download
        assert(#r.meta_paths >= 4, "meta for every copy: " .. #r.meta_paths)
        eq(CUSTOM[dune].custom_props.series, "Dune Saga") eq(CUSTOM[dune].custom_props.series_index, 1)
        eq(CUSTOM[dune].custom_props.authors, "Frank Herbert") eq(CUSTOM[dune].custom_props.description, "About Dune.epub")
        eq(COVERS[dune], "JPEGDATA")
        eq(#(sync.run(c).meta_paths or {}), 0, "unchanged books are left alone")

        -- did not finish, a rating, a review and a highlight go to the Library
        SIDE[emma] = { summary = { status = "abandoned", rating = 4, note = "Fun" },
            annotations = { { datetime = "2026-11-22 10:00:00", text = "It is a truth", note = "famous",
                              pos0 = "/body/p[1]", pos1 = "/body/p[2]", color = "red" },
                            { datetime = "2026-11-22 10:05:00", text = "", pos0 = "/body/p[3]" } } }
        ex.set_local(c, "dl2", { status = "dnf" })
        r = sync.run(c)
        eq(r.statuses, 1) eq(r.notes, 1)
        local cl = calls(c)
        eq(cl[1], 'status 2 {"rating": 4, "status": "dnf"}')
        eq(cl[2], 'highlight 2 {"cfi": "koreader:/body/p[1]|/body/p[2]", "color": "pink", "note": "famous", "text": "It is a truth"}')
        r = sync.run(c)
        eq(r.statuses, 0) eq(r.notes, 0) eq(#calls(c), 2, "nothing sent twice")
        -- a book finished in KOReader: Finished, and 100% for the position
        SIDE[dune] = { summary = { status = "complete", modified = "2026-11-01" } }
        r = sync.run(c)
        eq(r.collect_error, nil) eq(r.statuses, 1, "st") eq(r.positions, 1, "pos")
        eq(calls(c)[3], 'status 1 {"finished_at": "2026-11-01T12:00:00Z", "status": "finished"}')
        eq(util.load_table(c.status_path).dl1.finished_at, util.iso_time("2026-11-01T12:00:00Z"))

        -- sync on close: a changed note goes out at once, nothing else runs, no log line
        SIDE[emma].annotations[1].note = "most famous"
        local pc = {}
        for k, v in pairs(c) do pc[k] = v end
        pc.push_only, pc.only_paths = true, { [emma] = true }
        local logn = #util.load_table(c.log_path)
        r = sync.run(pc)
        eq(r.kind, "push") eq(r.notes, 1) eq(r.downloaded, 0)
        eq(calls(c)[4]:match("^patch (%d+)"), calls(c)[2] and "102" or "?") -- the id the server gave
        eq(#util.load_table(c.log_path), logn, "no log line for a push")

        -- next in series: in the catalog, and asked of the Library when it is not
        require("socket.http").request{ url = c.server .. "/test/add", headers = { Authorization = "Bearer tok" } }
        sync.update_state(c, function(st) st.next_wanted = { dl1 = { at = os.time() }, dl2 = { at = os.time() } } end)
        r = sync.run(c)
        eq(r.next_error, nil)
        eq(r.next_queued and r.next_queued[1], "New.epub", "next book put on Read later")
        local found = false
        for _, l in ipairs(calls(c)) do if l == "nextqueue 2" then found = true end end
        assert(found, "the Library was asked to find Emma's next book")
        local st = util.load_table(c.state_path)
        eq(st.next_wanted.dl1, nil) eq(st.next_wanted.dl2.asked, true)
        local cat = util.load_table(c.catalog_path)
        eq(ex.next_in_catalog(cat, (ex.book_of(cat, "dl1"))).title, "New.epub")
        eq(ex.next_in_catalog(cat, (ex.book_of(cat, "dl2"))), nil)

        -- remove finished books after 7 days: Shared finished 10 days ago, Dune on 2026-11-01
        ex.set_local(c, "dl3", { status = "read", finished_at = os.time() - 10 * 86400 })
        SIDE[dune].summary.status = "reading"  -- re-reading Dune: kept
        c.remove_after_days = 7
        r = sync.run(c)
        eq(r.auto_removed[1], "Shared.epub")
        eq(readFile(shared1), nil) eq(readFile(shared2), nil)
        assert(io.open(dune), "a book being re-read is kept")
        local undo = util.load_table(c.removed_path)
        eq(#undo, 1) eq(undo[1].why, "days") eq(#undo[1].paths, 2)
        r = sync.run(c)
        eq(readFile(shared2), nil, "not downloaded again") eq(#r.auto_removed, 0)
        -- undo: back at the next sync, in both places, and not removed again by itself
        ex.restore(c, undo[1])
        eq(#util.load_table(c.removed_path), 0)
        r = sync.run(c)
        eq(#readFile(shared1), 2000) eq(#readFile(shared2), 2000)
        eq(#r.auto_removed, 0, "a book brought back stays")
        c.remove_after_days = nil

        -- storage budget: room is made by removing the book finished longest ago
        SIDE[dune].summary = { status = "complete", modified = os.date("!%Y-%m-%d", os.time() - 2 * 86400) }
        os.remove(emma)
        st = util.load_table(c.state_path)
        local used = ex.used_bytes(st)
        c.budget = used - 1000  -- Emma (3000) only fits once Dune (5000) is gone
        r = sync.run(c)
        eq(r.auto_removed[1], "Dune.epub") eq(readFile(dune), nil)
        eq(#readFile(emma), 3000, "downloaded after making room")
        eq(util.load_table(c.removed_path)[1].why, "budget")
        os.remove(emma)
        c.budget = 1000
        r = sync.run(c)
        assert(r.budget_full and r.storage_full and r.error:find("budget"), tostring(r.error))
        c.budget = nil

        -- a folder that prefers PDF; all formats
        c.folder_formats = { Reads = "pdf" }
        r = sync.run(c)
        eq(#readFile(c.base .. "/Reads/Shared.pdf"), 2500, "PDF for Reads")
        eq(readFile(c.base .. "/Sci_Fi_ Classics/Shared.pdf"), nil, "EPUB elsewhere")
        c.folder_formats, c.format = nil, "all"
        r = sync.run(c)
        eq(#readFile(c.base .. "/Sci_Fi_ Classics/Shared.pdf"), 2500, "all formats")
    end)
    stop(port)
    if not ok then error(err, 0) end
end
test("v2.3: status, ratings, notes, push on close, next in series, removal + undo, budget, formats, covers", function() v23(18746) end)

test("v2.3: an older Library without the status call", function()
    local port = 18747
    start(port, "v23,nostatus")
    local ok, err = pcall(function()
        local c = cfg(port, "old")
        c.status_path, c.positions_path = tmp .. "/old.status", tmp .. "/old.pos"
        sync.run(c)
        ex.set_local(c, "dl1", { status = "read" })
        ex.set_local(c, "dl2", { status = "dnf", rating = 3 })
        local r = sync.run(c)
        assert(r.status_unsupported, "says the server cannot take it")
        local s = util.load_table(c.status_path)
        eq(s.dl1.sent_status, "read", "Finished went out as 100%")
        eq(s.dl2.sent_status, nil, "Did not finish waits") eq(s.dl2.sent_rating, nil)
    end)
    stop(port)
    if not ok then error(err, 0) end
end)

test("v2.4: status queue against the Library's status call", function()
    local sent = {}
    local answer = {}  -- download id -> code for the PUT
    local c = { server = "http://x", headers = {}, status_path = tmp .. "/q.status" }
    os.execute("mkdir -p '" .. tmp .. "'")
    c.send = function(method, url, _h, body)
        local id = tonumber(url:match("/api/downloads/(%d+)/"))
        sent[#sent + 1] = method .. " " .. id .. " " .. url:match("/(%a+)$") .. " " .. body
        if method == "GET" then return id == 7 and 404 or 200, "{}" end
        local code = answer[id] or 200
        if code == 200 then return 200, '{"status": "dnf", "rating": 3.5}' end
        return code, code == 404 and "<h1>Not Found</h1>" or '{"error": "no"}'
    end
    util.save_table(c.status_path, {
        dl1 = { status = "dnf", rating = 3.3, at = 1 },          -- sent, rating in half steps
        dl2 = { status = "paused", at = 1 },                     -- the Library has no On hold
        dl3 = { status = "read", finished_at = 0, rating = 5, sent_rating = 5 }, -- only the status
        dl7 = { status = "dnf" },                                -- gone from the server
        dl8 = { rating = 9 },                                    -- refused
    })
    answer[7], answer[8] = 404, 400
    local n, unsupported = ex.push_status(c)
    eq(n, 2) eq(unsupported, false)
    local s = util.load_table(c.status_path)
    eq(s.dl1.sent_status, "dnf") eq(s.dl1.sent_rating, 3.3) eq(s.dl2.sent_status, "paused")
    eq(s.dl3.sent_status, "read") eq(s.dl7.sent_status, "dnf") eq(s.dl8.sent_rating, 9)
    table.sort(sent)
    eq(table.concat(sent, "\n"), table.concat({
        'GET 7 position ',
        'PUT 1 status {"rating": 3.5000, "status": "dnf"}',
        'PUT 3 status {"finished_at": "1970-01-01T00:00:00Z", "status": "finished"}',
        'PUT 7 status {"status": "dnf"}',
        'PUT 8 status {"rating": 5}',
    }, "\n"))
    -- a failed sync keeps the queue; the next one sends it
    sent = {}
    ex.set_local(c, "dl1", { status = "reading" })
    c.send = function() return nil, "timeout" end
    eq((ex.push_status(c)), 0)
    eq(util.load_table(c.status_path).dl1.sent_status, "dnf", "kept")
    c.send = function(method, url, _h, body) sent[#sent + 1] = body return 200, "{}" end
    eq((ex.push_status(c)), 1)
    eq(sent[1], '{"status": "reading"}')
    eq(util.load_table(c.status_path).dl1.sent_status, "reading")
    eq((ex.push_status(c)), 0, "nothing sent twice")
    eq(ex.half_rating(0.2), 0.5) eq(ex.half_rating(4.74), 4.5) eq(ex.half_rating(0), nil)
end)

test("formats: pick and kepub", function()
    local f = { { ext = "pdf", key = "a" }, { ext = "epub", key = "b" }, { ext = "kepub", key = "c" } }
    eq(sync.pick_format(f, "epub")[1].key, "b") eq(sync.pick_format(f, "kepub")[1].key, "c")
    eq(sync.pick_format(f, "mobi")[1].key, "b", "falls back to the order") eq(#sync.pick_format(f, "all"), 3)
    eq(sync.ext_of("/opds/files/1/x.kepub.epub"), "kepub") eq(sync.ext_of("/opds/files/1/x.EPUB"), "epub")
    eq(sync.format_pref({ format = "pdf", folder_formats = { A = "kepub" } }, "A"), "kepub")
    eq(sync.format_pref({ format = "pdf", folder_formats = {} }, "B"), "pdf")
    eq(util.json_object({ b = 'x"y\n', a = 1.5, c = true }), '{"a": 1.5000, "b": "x\\"y\\n", "c": true}')
end)

local more = require("librarysync/more")

-- A stand-in for libkoreader-lfs over the shell (the specs have no LuaFileSystem).
local fake_lfs = {
    dir = function(d)
        local h = assert(io.popen("ls -a '" .. d .. "' 2>/dev/null"))
        local names = {}
        for l in h:lines() do names[#names + 1] = l end
        h:close()
        local i = 0
        return function() i = i + 1 return names[i] end
    end,
    attributes = function(p, what)
        local h = io.popen("[ -d '" .. p .. "' ] && echo directory || ([ -f '" .. p .. "' ] && echo file)")
        local m = h:read("*l") h:close()
        return m
    end,
}

test("v2.5: goals, battery rules, ordering, stats", function()
    local now = os.time{ year = 2026, month = 11, day = 23, hour = 12 }
    local st = {
        a = { status = "read", finished_at = os.time{ year = 2026, month = 11, day = 2, hour = 12 } },
        b = { status = "read", finished_at = os.time{ year = 2026, month = 3, day = 2, hour = 12 } },
        c = { status = "read", finished_at = os.time{ year = 2025, month = 11, day = 2, hour = 12 } },
        d = { status = "reading" },
    }
    local y, m = more.finished_counts(st, now) eq(y, 2) eq(m, 1)
    local g = more.goal_progress({ year = 24, month = 2 }, st, now)
    eq(g.year.done, 2) eq(g.year.goal, 24) assert(g.year.pace > 21 and g.year.pace < 22, g.year.pace)
    eq(g.month.done, 1) assert(math.abs(g.month.pace - 2 * 23 / 30) < 1e-9)
    eq(more.goal_progress({}, st, now).year, nil, "no goal, no line")

    -- battery: charging always allows; override allows everything; unknown power allows
    eq(more.power_ok({ min_battery = 20 }, { capacity = 50, charging = false }), true)
    local ok, why = more.power_ok({ min_battery = 20 }, { capacity = 12, charging = false })
    eq(ok, false) assert(why:find("12%%"), why)
    eq(more.power_ok({ min_battery = 20 }, { capacity = 12, charging = true }), true)
    ok, why = more.power_ok({ charger_only = true }, { capacity = 90, charging = false })
    eq(ok, false) eq(why, "the device is not charging")
    eq(more.power_ok({ charger_only = true, min_battery = 50, override = true }, { capacity = 5, charging = false }), true, "override")
    eq(more.power_ok({ charger_only = true }, nil), true, "device cannot tell")

    -- bandwidth: Read later first, then smallest; big ones left for later
    local items = { { key = "a", size = 5000 }, { key = "b", size = 100 }, { key = "c" },
                    { key = "d", size = 9000, queued = true }, { key = "e", size = 100 } }
    local keep, later = more.order_items(items, true, 4000)
    eq(#keep, 4) eq(#later, 1) eq(later[1].key, "a")
    eq(keep[1].key, "d", "read later goes first, even when big") eq(keep[2].key, "b") eq(keep[3].key, "e") eq(keep[4].key, "c")
    keep = more.order_items(items, false, nil)
    eq(#keep, 5) eq(keep[1].key, "a", "order kept when off")
    eq(more.trusted({ "Home" }, "Home"), true) eq(more.trusted({ "Home" }, "Cafe"), false) eq(more.trusted({ "Home" }, nil), false)

    -- stats: a page turn counts a page and the time on the page before (not long breaks)
    local stats, sess = { days = {} }, {}
    eq(more.stats_tick(stats, sess, 10, now), false, "opening a book is not a page read")
    eq(more.stats_tick(stats, sess, 11, now + 40), true)
    more.stats_tick(stats, sess, 12, now + 100)
    more.stats_tick(stats, sess, 12, now + 110)  -- same page: nothing
    more.stats_tick(stats, sess, 13, now + 2000) -- after a break: the page, not the time
    local day = stats.days[os.date("%Y-%m-%d", now)]
    eq(day.pages, 3) eq(day.secs, 100)
    stats.days["2020-01-01"] = { pages = 1, secs = 1 }
    more.stats_prune(stats, now)
    eq(stats.days["2020-01-01"], nil, "old days dropped")
    local merged = more.stats_merge({ days = { [os.date("%Y-%m-%d", now)] = { pages = 2, secs = 60 } } }, stats)
    eq(merged.days[os.date("%Y-%m-%d", now)].pages, 5)
    local sum = more.stats_summary(merged, now, 7, 4)
    eq(sum.today.pages, 5) eq(sum.today.secs, 160) eq(#sum.days, 7) eq(#sum.weeks, 4)
    eq(sum.weeks[1].pages, 5) eq(sum.weeks[1].from, "2026-11-23", "the week starts on Monday")
    eq(more.duration(3900), "1 h 05 min") eq(more.duration(59), "0 min") eq(more.duration(720), "12 min")
end)

test("v2.5: duplicates, moves and the new-on-device list", function()
    eq(more.title_key("/L/Dune Saga/Dune Saga #1 - Dune.epub"), "dune")
    eq(more.title_key("/L/x/Dune.pdf"), "dune")
    eq(more.title_key("/L/x/Emma (12).epub"), "emma")
    local base = tmp .. "/dups"
    os.execute("mkdir -p '" .. base .. "/A' '" .. base .. "/B' '" .. base .. "/A/x.sdr' '" .. base .. "/.hidden'")
    writeFile(base .. "/A/Dune.epub", "1") writeFile(base .. "/B/Dune Saga #1 - Dune.epub", "1")
    writeFile(base .. "/B/Dune.pdf", "1") writeFile(base .. "/A/Emma.epub", "1")
    writeFile(base .. "/A/x.sdr/metadata.epub.lua", "1") writeFile(base .. "/.hidden/Emma.epub", "1")
    writeFile(base .. "/A/Emma.epub.part", "1") writeFile(base .. "/A/notes.jpg", "1")
    local paths = more.walk(fake_lfs, base)
    eq(#paths, 4, table.concat(paths, ","))
    local groups = more.duplicates(paths)
    eq(#groups, 1) eq(groups[1].id, "dune") eq(#groups[1].paths, 3)
    eq(#more.duplicates(paths, { dune = true }), 0, "kept all")
    eq(more.suggest_keep(groups[1].paths, function(p) return p:find("pdf") end, "epub"), base .. "/B/Dune.pdf", "read here wins")
    eq(more.suggest_keep(groups[1].paths, nil, "pdf"), base .. "/B/Dune.pdf")
    eq(more.suggest_keep(groups[1].paths, nil, "epub"), base .. "/A/Dune.epub")

    -- moving: the file goes, its record follows, and the old place is not filled again
    os.execute("mkdir -p '" .. base .. "/C'")
    local new = more.move_file(base .. "/A/Emma.epub", base .. "/C")
    eq(new, base .. "/C/Emma.epub") eq(readFile(base .. "/A/Emma.epub"), nil)
    local nope, err = more.move_file(new, base .. "/C") eq(nope, new, "same place")
    writeFile(base .. "/A/Emma.epub", "2")
    nope, err = more.move_file(base .. "/A/Emma.epub", base .. "/C")
    eq(nope, nil) assert(err:find("already"), err)
    local st = { files = { dl2 = { [base .. "/A/Emma.epub"] = 1, [base .. "/B/Emma.epub"] = 1 }, dl9 = { [base .. "/A/Gone.epub"] = 1 } } }
    more.note_moves(st, { [base .. "/A/Emma.epub"] = new, [base .. "/A/Gone.epub"] = false })
    eq(st.files.dl2[new], 1) eq(st.files.dl2[base .. "/A/Emma.epub"], nil) eq(st.files.dl9, nil)
    assert(st.skip_dests[base .. "/A/Emma.epub"] and st.skip_dests[base .. "/A/Gone.epub"] and st.moved[new])
    local its = { { key = "dl2", dests = { base .. "/A/Emma.epub", base .. "/B/Emma.epub" } },
                  { key = "dl9", dests = { base .. "/A/Gone.epub" } },
                  { key = "dl5", dests = { base .. "/A/Gone.epub" }, queued = true } }
    eq(more.drop_skipped(its, st.skip_dests), 1)
    eq(#its, 2) eq(#its[1].dests, 1) eq(its[1].dests[1], base .. "/B/Emma.epub") eq(its[2].key, "dl5", "Read later still goes")

    local rp = tmp .. "/recent.lua"
    more.add_recent(rp, { { name = "a", path = "/a" }, { name = "b", path = "/b" } }, 100)
    more.add_recent(rp, { { name = "a2", path = "/a" } }, 200)
    local list = util.load_table(rp)
    eq(#list, 2) eq(list[1].name, "a2", "newest first, once per file") eq(list[2].name, "b")
end)

local function v25(port)
    start(port, "range")
    local ok, err = pcall(function()
        local c = cfg(port, "v25")
        c.catalog_path, c.recent_path = tmp .. "/v25.catalog", tmp .. "/v25.recent"
        c.small_first, c.defer_over = true, 2500
        local r = sync.run(c)
        eq(r.deferred, 1, "Dune (5000 bytes) waits for a trusted network")
        eq(readFile(c.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"), nil)
        eq(#readFile(c.base .. "/Reads/Shared.epub"), 2000)
        local recent = util.load_table(c.recent_path)
        eq(recent[#recent].name, "Shared.epub", "smallest came first")
        local log = util.load_table(c.state_path .. "x") -- no log path: nothing written
        eq(log, nil)
        c.defer_over = nil
        r = sync.run(c)
        eq(r.deferred, nil) eq(r.downloaded, 1)
        recent = util.load_table(c.recent_path)
        eq(recent[1].name, "Dune Saga #1 - Dune.epub") eq(recent[1].path, c.base .. "/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub")

        -- moved away by hand (bulk move): not downloaded again, and never offered for cleanup
        local away = tmp .. "/v25-away"
        os.execute("mkdir -p '" .. away .. "'")
        local old = c.base .. "/Reads/Shared.epub"
        local new = more.move_file(old, away)
        sync.update_state(c, function(st) more.note_moves(st, { [old] = new }) end)
        r = sync.run(c)
        eq(readFile(old), nil, "the old place stays empty")
        eq(#readFile(c.base .. "/Sci_Fi_ Classics/Shared.epub"), 2000, "the other folder keeps its copy")
        local st = util.load_table(c.state_path)
        eq(sync.key_for_path(st, new), "dl3", "progress still syncs from the new place")
        local cands = sync.cleanup_candidates(c, util.load_table(c.catalog_path), st)
        for _, p in ipairs(cands) do assert(p ~= new, "moved book offered for removal") end
        -- downloading it on purpose fills the place again
        local file = { key = "dl3", url = c.server .. "/opds/files/3/Shared.epub", size = 2000, name = "Shared.epub" }
        assert(sync.download_one(c, "Reads", file))
        eq(util.load_table(c.state_path).skip_dests[old], nil)
        eq(util.load_table(c.recent_path)[1].path, old)

        -- the health check, in plain words
        c.transport, c.headers = require("librarysync/http").get, require("librarysync/http").auth_headers(c)
        local lines, verdict = more.health(c)
        eq(verdict, "all good")
        local text = {}
        for _, l in ipairs(lines) do text[#text + 1] = l.text end
        text = table.concat(text, "\n")
        assert(text:find("Account: me %(admin%)") and text:find("version 1.33.0") and text:find("Highlights and notes: supported"), text)
        local bad = cfg(port, "v25bad") bad.password = "nope"
        bad.transport, bad.headers = c.transport, require("librarysync/http").auth_headers(bad)
        lines, verdict = more.health(bad)
        eq(verdict, "sign-in refused") eq(lines[#lines].ok, false)
        local off = cfg(18799, "v25off")
        off.transport, off.headers = c.transport, c.headers
        lines, verdict = more.health(off)
        eq(verdict, "connection refused") assert(lines[1].text:find("refused the connection"), lines[1].text)
        lines, verdict = more.health({})
        eq(verdict, "not set up")
    end)
    stop(port)
    if not ok then error(err, 0) end
end

test("v2.5: bandwidth mode, moved books, new on this device, health check", function() v25(18748) end)

test("v2.5: health check names what an older server lacks", function()
    local port = 18749
    start(port, "nostatus")
    local ok, err = pcall(function()
        local c = cfg(port, "v25old")
        c.transport, c.headers = require("librarysync/http").get, require("librarysync/http").auth_headers(c)
        local lines, verdict = more.health(c)
        eq(verdict, "1 missing")
        local found = false
        for _, l in ipairs(lines) do
            if l.ok == false and l.text:find("Did not finish and ratings: not on this server %(needs Library 1.33") then found = true end
        end
        assert(found, "names the missing feature")
    end)
    stop(port)
    if not ok then error(err, 0) end
end)

test("https: never asks LuaSec for redirects (it refuses them), follows through LuaSocket", function()
    local real_http, real_https = package.loaded["socket.http"], package.loaded["ssl.https"]
    local seen = {}
    package.loaded["socket.http"] = { request = function(p) seen.socket = p return 1, 200, {} end }
    package.loaded["ssl.https"] = { request = function(p)
        if p.redirect then return nil, "redirect not supported" end
        return 1, 200, {} end }
    package.loaded["librarysync/http"] = nil
    local h = require("librarysync/http")
    eq(h.get("https://lib.example/opds", {}, function() return 1 end), 200, "via LuaSocket")
    eq(seen.socket.url, "https://lib.example/opds")
    -- an older LuaSocket without https: LuaSec directly, without redirect
    package.loaded["socket.http"] = { request = function() return nil, "unknown scheme 'https'" end }
    eq(h.get("https://lib.example/opds", {}, function() return 1 end), 200, "LuaSec fallback")
    package.loaded["socket.http"], package.loaded["ssl.https"] = real_http, real_https
    package.loaded["librarysync/http"] = nil
end)

test("health: network errors say which step failed", function()
    local more = require("librarysync/more")
    local _, v = more.describe_error("host or service not provided, or not known", "https://lib.example")
    eq(v, "address not found")
    _, v = more.describe_error("certificate verify failed", "https://lib.example") eq(v, "secure connection failed")
    _, v = more.describe_error("timeout", "https://lib.example") eq(v, "timed out")
    _, v = more.describe_error("connection refused", "https://lib.example") eq(v, "connection refused")
end)

test("progress: books, bytes, speed, time left and the status text", function()
    local P = require("librarysync/progress")
    local t = 100
    local tr = P.new(function() return t end)
    tr:setPhase("Reading the catalog")
    eq(tr:snapshot().phase, "Reading the catalog")
    assert(P.format(tr:snapshot()):find("Reading the catalog", 1, true))
    tr:plan({ { size = 4 * 1048576 }, { size = 4 * 1048576 }, { size = nil } })
    eq(tr.books_total, 3) eq(tr.bytes_total, 8 * 1048576) eq(tr.unknown_size, 1)
    tr:begin("A.epub", 4 * 1048576)
    for i = 1, 4 do t = t + 1 tr:bytes(i * 1048576) end  -- 1 MB/s
    tr:finish(true, 4 * 1048576)
    tr:setPhase("ignored while downloading")
    tr:begin("B.epub", 4 * 1048576)
    t = t + 1 tr:bytes(1048576)
    local s = tr:snapshot()
    eq(s.books_done, 1) eq(P.pending(s), 2) eq(s.bytes_done, 5 * 1048576) eq(s.current, "B.epub")
    eq(math.floor(s.speed + 0.5), 1048576, "1 MB/s")
    -- 3 MB of B left plus one unknown book counted as an average one (4 MB): 7 s
    eq(s.eta, 7)
    local text = P.format(s)
    for _, want in ipairs({ "1 done", "2 to go", "5.0 MB of 8.0 MB", "Now: B.epub (1.0 MB of 4.0 MB)",
                            "1.0 MB/s", "about 7 s" }) do
        assert(text:find(want, 1, true), "missing " .. want .. " in\n" .. text)
    end
    eq(P.short(s), "1 of 3 books · 62% · 7 s left")
    tr:finish(false)
    eq(tr:snapshot().failed, 1) eq(tr.bytes_total, 4 * 1048576, "a failed book no longer counts")
    eq(P.duration(3725), "1 h 02 min") eq(P.duration(250), "4 min 10 s")
    -- estimates before a sync: measured speed, or a guess
    eq(P.estimate(10 * 1048576, 0, 5, 1048576), 10)
    eq(P.estimate(4 * 1048576, 1, 3, 1048576), 6, "unknown size counted as an average book")
    assert(P.estimate_text(10 * 1048576, 0, 5, 1048576):find("about 10 s at your recent speed (1.0 MB/s)", 1, true))
    assert(P.estimate_text(10 * 1048576, 0, 5, nil):find("a guess", 1, true))
    eq(P.blend_speed(nil, 100), 100) eq(P.blend_speed(100, 200), 160)
    -- the window forgets old samples: a stall shows a falling speed
    t = t + 30 tr:sample()
    assert(tr:speed() < 1048576 / 4, "speed falls when nothing arrives")
    -- what the background process writes survives the state file round trip
    local p = tmp .. "/progress-snap.lua"
    util.save_table(p, tr:snapshot())
    eq(util.load_table(p).books_total, 3)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
