-- UI smoke test: main.lua + browser.lua with stubbed KOReader modules, against spec/server.py.
-- luajit spec/ui.lua
package.path = "./librarysync.koplugin/?.lua;" .. package.path
local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/ls-ui-" .. os.time() .. math.random(1e6)
os.execute("mkdir -p '" .. tmp .. "'")
local port = 18751

local shown, opened, scheduled = {}, {}, {}
local function widget(name)
    local W = { name = name }
    function W:new(o) o = o or {} o.kind = name return setmetatable(o, { __index = W }) end
    return W
end
local Menu = widget("Menu")
function Menu:new(o) o.kind = "Menu" o.page, o.perpage = 1, 10 return setmetatable(o, { __index = Menu }) end
function Menu:switchItemTable(title, items, n, _, sub)
    if title then self.title = title end
    self.item_table, self.subtitle = items, sub or self.subtitle
    self.page = n and n > 0 and math.floor((n - 1) / self.perpage) + 1 or 1
end
function Menu:updateItems() self.updated = (self.updated or 0) + 1 end
local InputDialog = widget("InputDialog")
function InputDialog:onShowKeyboard() end
function InputDialog:getInputText() return self.input end

local stubs = {
    ["datastorage"] = { getSettingsDir = function() return tmp end, getDataDir = function() return tmp end },
    ["dispatcher"] = { registerAction = function() end },
    ["ui/widget/infomessage"] = widget("InfoMessage"),
    ["ui/widget/confirmbox"] = widget("ConfirmBox"),
    ["ui/widget/inputdialog"] = InputDialog,
    ["ui/widget/menu"] = Menu,
    ["ui/widget/textviewer"] = widget("TextViewer"),
    ["ui/widget/buttondialog"] = widget("ButtonDialog"),
    ["ui/event"] = { new = function(_, name, arg) return { name = name, arg = arg } end },
    ["readcollection"] = { coll = {}, addCollection = function(self, n) self.coll[n] = {} end,
        addItem = function(self, f, n) self.coll[n][f] = { file = f } end,
        removeItem = function(self, f, n) self.coll[n][f] = nil end,
        removeCollection = function(self, n) self.coll[n] = nil end,
        write = function(self) self.written = (self.written or 0) + 1 end },
    ["luasettings"] = { open = function() local d = {} return { data = d,
        readSetting = function(_, k) return d[k] end, saveSetting = function(_, k, v) d[k] = v end, flush = function() end } end },
    ["ui/network/manager"] = { runWhenOnline = function(_, f) f() end },
    ["ui/trapper"] = { wrap = function(_, f) f() end, info = function() return true end, clear = function() end },
    ["ui/uimanager"] = {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function(_, w) for i = #shown, 1, -1 do if shown[i] == w then table.remove(shown, i) end end end,
        scheduleIn = function(_, t, f) scheduled[#scheduled + 1] = f end,
        nextTick = function(_, f) f() end, forceRePaint = function() end,
    },
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, t) t.new = function(cls, o) return setmetatable(o or {}, { __index = cls }) end return t end },
    ["libs/libkoreader-lfs"] = { attributes = function(p) local f = io.open(p) if f then f:close() return "file" end end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s, ...) local a = { ... } return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end },
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } },
    ["apps/reader/readerui"] = { showReader = function(_, p) opened[#opened + 1] = p end },
    ["apps/filemanager/filemanager"] = {},
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
_G.G_reader_settings = { readSetting = function() return tmp end }

local function last(kind) for i = #shown, 1, -1 do if shown[i].kind == kind then return shown[i] end end end
local function find(menu, text)
    for _, it in ipairs(menu.item_table) do if (it.text or "Stop the running sync"):find(text, 1, true) then return it end end
    error("no item " .. text)
end
local function sync_key(st, path) return require("librarysync/sync").key_for_path(st, path) end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

os.execute(string.format("python3 -I spec/server.py %d >/dev/null 2>&1 &", port))
local socket = require("socket")
for _ = 1, 50 do local c = socket.tcp() if c:connect("127.0.0.1", port) then c:close() break end socket.sleep(0.1) end

local ok, err = pcall(function()
    local LS = require("main")
    local menu_items = {}
    local p = LS:new{ ui = { menu = { registerToMainMenu = function(_, w) w:addToMainMenu(menu_items) end } } }
    p:init()
    p:set("server", "http://127.0.0.1:" .. port) p:set("username", "me") p:set("password", "pw")
    p:set("base", tmp .. "/Library")

    local requests = 0
    local http = require("librarysync/http")
    local real = http.get
    http.get = function(...) requests = requests + 1 return real(...) end

    -- before any sync: nothing to browse, no server contact
    p:browse()
    local m = last("Menu")
    find(m, "Nothing here yet")
    eq(requests, 0, "browsing before a sync makes no request")
    m.close_callback()

    -- settings opened from the Library show On/Off and update in place
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "Settings"))
    local s = last("Menu")
    eq(s.title, "Library sync settings")
    local it = find(s, "Put series in file names")
    eq(it.mandatory, "On")
    s:onMenuSelect(it)
    eq(find(s, "Put series in file names").mandatory, "Off")
    s:onMenuSelect(find(s, "Put series in file names"))
    assert(find(s, "User name").dim == nil and find(s, "API token").dim, "dims the unused login")
    s.close_callback()

    -- sync (no fork in the stub -> foreground) saves the catalog
    p:set("background", false)
    m:onMenuSelect(find(m, "Sync everything now"))
    local msg = last("InfoMessage").text
    assert(msg:find("Downloaded: 3") and msg:find("Failed: 1"), msg)
    assert(io.open(tmp .. "/Library/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"))
    eq(m.title, "Library", "browser refreshed after the sync")
    assert(m.subtitle:find("Last sync"), tostring(m.subtitle))

    -- browse everything from the saved copy: no requests at all
    requests = 0
    m:onMenuSelect(find(m, "Folders"))
    m:onMenuSelect(find(m, "Reads"))
    eq(m.title, "Reads")
    eq(find(m, "Shared").mandatory, "✓ ")
    m.onReturn() m.onReturn()
    m:onMenuSelect(find(m, "Recently added"))
    eq(m.item_table[2].text, "Loose.epub", "newest first")
    eq(m.item_table[2].mandatory, "", "book outside folders is not synced")
    m.onReturn()
    m:onMenuSelect(find(m, "Series"))
    m:onMenuSelect(find(m, "Dune Saga"))
    eq(m.item_table[1].text, "Dune Saga #1 – Dune.epub") eq(m.item_table[1].mandatory, "✓ ")
    m.onReturn() m.onReturn()
    m:onMenuSelect(find(m, "Authors"))
    m:onMenuSelect(find(m, "Jane Austen"))
    find(m, "Emma")
    m.onReturn() m.onReturn()
    eq(find(m, "Continue reading").mandatory, "1")
    m:onMenuSelect(find(m, "Search"))
    local d = last("InputDialog") d.input = "emma"
    d.buttons[1][3].callback()
    eq(m.title, "Search: emma") find(m, "Emma")
    eq(requests, 0, "browsing makes no request")

    -- tapping a book that is on the device opens it
    m:onMenuSelect(find(m, "Emma"))
    eq(opened[1], tmp .. "/Library/Reads/Emma & Co.epub")

    -- a book not on the device: asks, then fetches just that one
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "All books"))
    m:onMenuSelect(find(m, "Loose"))
    last("ButtonDialog").buttons[1][1].callback()
    assert(io.open(tmp .. "/Library/Loose.epub"), "no folder: into the download folder")
    eq(find(m, "Loose").mandatory, "✓ ")

    -- long-press a book: details from the saved catalog, with Open
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "Series"))
    m:onMenuSelect(find(m, "Dune Saga"))
    m:onMenuHold(m.item_table[1])
    local tv = last("TextViewer")
    assert(tv.text:find("by Frank Herbert") and tv.text:find("Folders: Sci/Fi: Classics")
        and tv.text:find("On this device") and tv.text:find("About Dune.epub"), tv.text)
    eq(tv.buttons_table[1][2].text, "Open")
    m.close_callback()

    -- folders to sync: toggle one off; the folder list says so
    p:chooseFolders()
    local fm = last("Menu")
    eq(fm.title, "Folders to sync")
    eq(find(fm, "Reads").mandatory, "Everything")
    fm:onMenuSelect(find(fm, "Reads"))
    eq(find(fm, "Reads").mandatory, "Unread only")
    eq(p:config().folder_rules.Reads, "unread")
    fm:onMenuSelect(find(fm, "Reads")) eq(find(fm, "Reads").mandatory, "Newest 5")
    eq(p:config().folder_rules.Reads, 5)
    for _ = 1, 3 do fm:onMenuSelect(find(fm, "Reads")) end
    eq(find(fm, "Reads").mandatory, "Off")
    assert(p:config().skip_folders.Reads) eq(p:config().folder_rules.Reads, nil)
    fm.close_callback()
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "Folders"))
    eq(find(m, "Reads").mandatory, "not synced · 2")
    m.close_callback()
    p:set("skip_folders", {})
    p:set("folder_rules", {})

    -- cleanup: everything is still on the server
    p:cleanupBooks()
    assert(last("InfoMessage").text:find("Nothing to remove"), last("InfoMessage").text)

    -- reading: the place of a synced book is saved for the next sync
    local r = LS:new{ ui = { menu = { registerToMainMenu = function() end },
        document = { file = tmp .. "/Library/Reads/Emma & Co.epub", getPageCount = function() return 200 end },
        doc_settings = { readSetting = function() return nil end } } }
    r:init()
    r:onReaderReady()
    r:onPageUpdate(50)
    r:onCloseDocument()
    local pos = dofile(tmp .. "/librarysync_positions.lua")
    eq(pos.dl2.percent, 0.25) eq(pos.dl2.tz % 1, 0)
    p:set("background", false)
    p:syncNow()
    assert(last("InfoMessage").text:find("Reading progress sent: 1"), last("InfoMessage").text)

    -- background sync: a "forked" job (run in-process here), polled until done
    local fu = stubs["ffi/util"]
    local done = false
    p:set("background", true)
    fu.runInSubProcess = function(f) f() return 4242 end
    fu.isSubProcessDone = function() return done end
    p:syncNow()
    eq(require("librarysync/shared").pid, 4242, "job running")
    p:syncNow()
    assert(last("InfoMessage").text:find("already running"), "second sync refused")
    find({ item_table = menu_items.librarysync_settings.sub_item_table, }, "Stop the running sync")
    done = true
    table.remove(scheduled)()
    eq(require("librarysync/shared").pid, nil, "job finished")
    assert(last("InfoMessage").text:find("Failed: 1"), "summary shown: " .. last("InfoMessage").text)

    -- automatic sync: quick sync when Wi-Fi connects, quiet, at most once an hour
    local NM = stubs["ui/network/manager"]
    NM.isConnected = function() return true end
    p:set("auto_sync", "off")
    p:set("retry_on_wifi", false)
    p:autoCheck(true)
    eq(require("librarysync/shared").pid, nil, "off: nothing")
    p:set("auto_sync", "wifi")
    local before = #shown
    p:onNetworkConnected()
    table.remove(scheduled)()  -- the 5 s settle delay
    eq(require("librarysync/shared").pid, 4242, "auto sync started")
    eq(#shown, before, "no pop-up for an automatic sync")
    table.remove(scheduled)()  -- poll: done
    eq(require("librarysync/shared").pid, nil)
    p:onNetworkConnected() table.remove(scheduled)()
    eq(require("librarysync/shared").pid, nil, "not again within the hour")
    p:set("auto_sync", "daily") p:set("auto_last", 0)
    p:autoCheck(false)
    eq(require("librarysync/shared").pid, nil, "daily: last sync is recent")
    p:set("auto_sync", "off")

    -- storage line and the free-space setting
    assert(p:storageText():find("^Storage: Library %d+ MB · "), p:storageText())
    local item
    for _, it in ipairs(menu_items.librarysync_settings.sub_item_table) do
        if it.text_func and it.text_func():find("Keep free") then item = it end
    end
    item.callback() eq(p:get("min_free_mb"), 250)

    -- mark as finished from the reader menu
    local saved = {}
    local r2 = LS:new{ ui = { menu = { registerToMainMenu = function() end },
        document = { file = tmp .. "/Library/Reads/Emma & Co.epub", getPageCount = function() return 200 end },
        doc_settings = { readSetting = function() return nil end, saveSetting = function(_, k, v) saved[k] = v end } } }
    r2:init()
    local mi = {}
    r2:addToMainMenu(mi)
    mi.librarysync_finished.callback()
    eq(saved.summary.status, "complete")
    eq(dofile(tmp .. "/librarysync_positions.lua").dl2.percent, 1)
    assert(last("InfoMessage").text:find("next sync"), last("InfoMessage").text)

    -- resume and retry when Wi-Fi connects (auto sync off): the failed book, in the background
    p:set("retry_on_wifi", true) p:set("auto_sync", "off")
    local SH = require("librarysync/shared")
    done = false
    p:onNetworkConnected()
    table.remove(scheduled)()
    eq(SH.pid, 4242, "retry job started")
    done = true
    table.remove(scheduled)()
    eq(SH.pid, nil)
    local log = dofile(tmp .. "/librarysync_log.lua")
    eq(log[1].kind, "retry") eq(log[1].failed[1].name, "Broken.epub")
    eq(dofile(tmp .. "/librarysync_state.lua").failed.dl4.tries >= 2, true)
    p:onNetworkConnected() table.remove(scheduled)()
    eq(SH.pid, nil, "not again within 10 minutes")
    p:set("background", false)

    -- sync log screen
    p:showLog()
    local lv = last("TextViewer")
    assert(lv.text:find("Resume and retry") and lv.text:find("Broken.epub — "), lv.text)
    lv.buttons_table[1][2].callback()
    assert(last("TextViewer").title:find("2 of"), last("TextViewer").title)

    -- read later: marked from the browser, downloaded by the next sync
    os.remove(tmp .. "/Library/Loose.epub")
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "All books"))
    m:onMenuSelect(find(m, "Loose"))
    local bd = last("ButtonDialog")
    assert(bd.buttons[2][1].text:find("Read later"), bd.buttons[2][1].text)
    bd.buttons[2][1].callback()
    eq(find(m, "Loose").mandatory, "⏳ ", "queued mark")
    m.onReturn()
    eq(find(m, "Read later").mandatory, "1")
    m:onMenuSelect(find(m, "Read later"))
    find(m, "Loose")
    m.close_callback()
    p:syncNow()
    assert(io.open(tmp .. "/Library/Loose.epub"), "read-later book downloaded at the sync")
    eq(next(dofile(tmp .. "/librarysync_queue.lua")), nil)

    -- search the server: finds books, with a download for the ones not on the device
    requests = 0
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "Search"))
    d = last("InputDialog") d.input = "dune"
    d.buttons[1][2].callback()
    eq(m.title, "Server: dune") eq(requests, 1, "one search request")
    eq(find(m, "Dune").mandatory, "✓ ")
    m.close_callback()

    -- sync preview: a big sync stops and lists what will download, untick, start
    p:set("preview_min", 1)
    os.remove(tmp .. "/Library/Reads/Emma & Co.epub")
    p:syncNow()
    local pm = last("Menu")
    eq(pm.title, "Sync preview")
    local emma = find(pm, "Emma")
    assert(emma.text:find("^☑"), emma.text)
    pm:onMenuSelect(emma)
    assert(find(pm, "Emma").text:find("^☐"), "unticked")
    assert(pm.item_table[1].text:find("download 1 books"), pm.item_table[1].text)  -- Broken stays ticked
    pm:onMenuSelect(pm.item_table[1])
    eq(io.open(tmp .. "/Library/Reads/Emma & Co.epub"), nil, "unticked: not downloaded")
    assert(dofile(tmp .. "/librarysync_state.lua").declined.dl2, "remembered")
    p:set("preview_min", 0)

    -- two-way progress: a place read elsewhere is offered when the book opens
    p:set("preview_min", 0)
    local key_path = tmp .. "/Library/Sci_Fi_ Classics/Dune Saga #1 - Dune.epub"
    local rp = tmp .. "/librarysync_remote.lua"
    local f = io.open(rp, "wb") f:write("return { dl1 = { percent = 0.6, at = " .. (os.time() + 100) .. " } }") f:close()
    local events = {}
    local r3 = LS:new{ ui = { menu = { registerToMainMenu = function() end },
        handleEvent = function(_, e) events[#events + 1] = e end,
        document = { file = key_path, getPageCount = function() return 100 end },
        doc_settings = { readSetting = function(_, k) if k == "percent_finished" then return 0.1 end end } } }
    r3:init()
    r3:onReaderReady()
    table.remove(scheduled)()
    local cb = last("ConfirmBox")
    assert(cb.text:find("60%%") and cb.text:find("10%%"), cb.text)
    cb.ok_callback()
    eq(events[1].name, "GotoPercent") eq(events[1].arg, 60)
    r3:onReaderReady()
    local before2 = #shown
    table.remove(scheduled)()
    eq(#shown, before2, "asked only once")

    -- collections: shelves and series mirrored into KOReader's collections
    local RC = stubs["readcollection"]
    local it2
    for _, x in ipairs(menu_items.librarysync_settings.sub_item_table) do
        if x.text_func and x.text_func():find("KOReader collections from") then it2 = x end
    end
    it2.callback()  -- off -> shelves
    eq(p:get("collections"), "shelves")
    assert(RC.coll.Reads and next(RC.coll.Reads), "Reads shelf has books")
    eq(RC.coll["Sci/Fi: Classics"], nil, "series folder is not a shelf")
    it2.callback()  -- series
    assert(RC.coll["Dune Saga"] and next(RC.coll["Dune Saga"]), "series collection")
    eq(RC.coll.Reads, nil, "shelf removed when switched to series")

    -- v2.3 ----------------------------------------------------------------
    -- settings groups open as their own lists; removal settings ask before they turn on
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "Settings"))
    s = last("Menu")
    local grp = find(s, "Finished books and storage")
    eq(grp.mandatory, "›")
    s:onMenuSelect(grp)
    local gs = last("Menu")
    eq(gs.title, "Finished books and storage")
    gs:onMenuSelect(find(gs, "Storage budget"))
    local ask = last("ConfirmBox")
    assert(ask.text:find("1 GB") and ask.text:find("Removed books"), ask.text)
    eq(p:get("budget_gb", 0), 0, "not on before the answer")
    ask.ok_callback()
    eq(p:get("budget_gb"), 1)
    assert(find(gs, "Storage budget").text:find("1 GB"), "list updated")
    local nconfirm = #shown
    gs:onMenuSelect(find(gs, "Storage budget"))
    eq(p:get("budget_gb"), 2, "no question once it is on") eq(#shown, nconfirm)
    for _ = 1, 4 do gs:onMenuSelect(find(gs, "Storage budget")) end
    eq(p:get("budget_gb"), 0, "back to off")
    assert(p:storageText():find("^Storage: Library"), p:storageText())
    gs.close_callback() s.close_callback() m.close_callback()

    -- format per folder
    p:chooseFormats()
    local ff = last("Menu")
    eq(ff.title, "Format per folder") eq(find(ff, "Reads").mandatory, "as the default")
    ff:onMenuSelect(find(ff, "Reads"))
    eq(find(ff, "Reads").mandatory, "EPUB") eq(p:config().folder_formats.Reads, "epub")
    ff.close_callback()
    p:set("folder_formats", {})

    -- the reader's "Library: this book" menu: rate, did not finish, next in series
    local book = {}
    local r4 = LS:new{ ui = { menu = { registerToMainMenu = function() end },
        document = { file = tmp .. "/Library/Reads/Emma & Co.epub", getPageCount = function() return 200 end },
        doc_settings = { readSetting = function(_, k) return book[k] end, saveSetting = function(_, k, v) book[k] = v end } } }
    r4:init()
    local mi4 = {}
    r4:addToMainMenu(mi4)
    local sub = mi4.librarysync_book.sub_item_table
    sub[1].callback()
    local rd = last("ButtonDialog")
    eq(rd.buttons[2][1].text, "★★★★")
    rd.buttons[2][1].callback()
    eq(book.summary.rating, 4)
    local stat = dofile(tmp .. "/librarysync_status.lua")
    eq(stat.dl2.rating, 4)
    sub[2].callback()
    eq(book.summary.status, "abandoned")
    eq(dofile(tmp .. "/librarysync_status.lua").dl2.status, "dnf")
    assert(last("InfoMessage").text:find("did not finish"), last("InfoMessage").text)

    -- next in series: Dune #1 has no #2 in the Library: offer to ask for it at the next sync
    p:offerNext("dl1")
    local nq = last("ConfirmBox")
    assert(nq.text:find("Dune Saga") and nq.text:find("next sync"), nq.text)
    nq.ok_callback()
    assert(dofile(tmp .. "/librarysync_state.lua").next_wanted.dl1, "asked for at the next sync")
    local before3 = #shown
    p:offerNext("dl1")
    eq(#shown, before3, "offered once")

    -- removed books: the undo list brings one back at the next sync
    local loose = { key = "dl5", name = "Loose.epub", url = "http://127.0.0.1:" .. port .. "/opds/files/5/Loose.epub", size = 1000 }
    local uf = io.open(tmp .. "/librarysync_removed.lua", "wb")
    uf:write('return { { key = "dl5", title = "Loose", why = "days", at = 1, size = 1000, paths = { "' .. tmp .. '/Library/Loose.epub" }, file = { key = "dl5", name = "Loose.epub", url = "' .. loose.url .. '", size = 1000 } } }')
    uf:close()
    p:browse() m = last("Menu")
    eq(find(m, "Removed books").mandatory, "1")
    m:onMenuSelect(find(m, "Removed books"))
    local rm = last("Menu")
    eq(rm.title, "Removed books")
    rm:onMenuSelect(find(rm, "Loose"))
    local rb = last("ButtonDialog")
    rb.buttons[2][1].callback()
    eq(dofile(tmp .. "/librarysync_queue.lua").dl5.path, tmp .. "/Library/Loose.epub")
    assert(find(rm, "Nothing removed"), "list emptied")
    rm.close_callback() m.close_callback()

    -- statuses from the Library are written to KOReader's book status
    local SIDE = {}
    package.loaded["docsettings"] = {
        hasSidecarFile = function(_, path) return SIDE[path] ~= nil end,
        open = function(_, path)
            local d = SIDE[path] or {}
            SIDE[path] = d
            return { readSetting = function(_, k) return d[k] end, saveSetting = function(_, k, v) d[k] = v end, flush = function() end }
        end,
    }
    local rsf = io.open(tmp .. "/librarysync_remote_status.lua", "wb")
    rsf:write('return { dl1 = "read" }') rsf:close()
    eq(p:applyRemoteStatus(), 1)
    eq(SIDE[key_path].summary.status, "complete")
    eq(dofile(tmp .. "/librarysync_status.lua").dl1.sent_status, "read", "not sent back")
    eq(next(dofile(tmp .. "/librarysync_remote_status.lua")), nil)
    -- the newer form: status and rating (half stars show as whole ones, and are not sent back)
    rsf = io.open(tmp .. "/librarysync_remote_status.lua", "wb")
    rsf:write('return { dl1 = { status = "dnf", rating = 3.5 } }') rsf:close()
    eq(p:applyRemoteStatus(), 1)
    eq(SIDE[key_path].summary.status, "abandoned") eq(SIDE[key_path].summary.rating, 4)
    local s1 = dofile(tmp .. "/librarysync_status.lua").dl1
    eq(s1.sent_status, "dnf") eq(s1.rating, 4) eq(s1.sent_rating, 4)

    -- sync on close: with Wi-Fi on, a quiet background push right after the book closes
    local SH2 = require("librarysync/shared")
    done = false
    local nshown = #shown
    r4:set("server", "http://127.0.0.1:" .. port) r4:set("username", "me") r4:set("password", "pw")
    r4:set("base", tmp .. "/Library")
    r4:onCloseDocument()
    table.remove(scheduled)()  -- 2 s after closing
    eq(SH2.pid, 4242, "push started")
    done = true
    table.remove(scheduled)()  -- poll: done
    eq(SH2.pid, nil)
    eq(#shown, nshown, "nothing shown for the push")
    NM.isConnected = function() return false end
    local nsched = #scheduled
    r4:onCloseDocument()
    eq(#scheduled, nsched, "no Wi-Fi: nothing (sent at the next sync)")

    -- v2.5: battery and charger rules hold automatic syncs; the override and Sync now do not
    NM.isConnected = function() return true end
    local battery = { cap = 10, charging = false }
    stubs["device"].getPowerDevice = function() return {
        getCapacity = function() return battery.cap end, isCharging = function() return battery.charging end } end
    p:set("auto_sync", "wifi") p:set("auto_last", 0)
    p:autoCheck(true)
    eq(SH2.pid, nil, "low battery: no automatic sync")
    eq(p:get("auto_last"), 0)
    assert(p:powerText():find("on hold") and p:powerText():find("10 %%"), p:powerText())
    local tmp_items = {}
    p:addToMainMenu(tmp_items)
    local held = false
    for _i, it in ipairs(tmp_items.librarysync_settings.sub_item_table) do
        if it.text_func and it.text_func():find("automatic syncs on hold", 1, true) then held = true end
    end
    assert(held, "the sync status says why")
    battery.charging = true
    eq(p:powerAllowed(), true, "charging allows it")
    battery.charging = false
    p:set("charger_only", true) battery.cap = 90
    eq(p:powerAllowed(), false, "charger only")
    p:openGroup("Battery, Wi-Fi and data")
    local bw = last("Menu")
    eq(bw.title, "Battery, Wi-Fi and data")
    bw:onMenuSelect(find(bw, "Ignore battery and charger rules"))
    eq(p:get("power_override"), true)
    eq(find(bw, "Automatic syncs only while charging").dim, true, "dimmed under the override")
    done = false
    p:autoCheck(true)
    eq(SH2.pid, 4242, "override: the automatic sync runs")
    done = true
    table.remove(scheduled)()
    eq(SH2.pid, nil)
    bw:onMenuSelect(find(bw, "Bandwidth-friendly mode"))
    eq(p:get("bandwidth"), "small")
    local bc = p:config() p:applyBandwidth(bc)
    eq(bc.small_first, true) eq(bc.defer_over, nil)
    bw:onMenuSelect(find(bw, "Bandwidth-friendly mode"))
    bc = p:config() p:applyBandwidth(bc)
    eq(bc.defer_over, 25 * 1048576, "no trusted network known: big books wait")
    NM.getCurrentNetwork = function() return { ssid = "Home" } end
    bw:onMenuSelect(find(bw, "Trusted Wi-Fi"))
    eq(p:get("trusted_wifi")[1], "Home")
    bc = p:config() p:applyBandwidth(bc)
    eq(bc.defer_over, nil, "trusted network: everything goes")
    bw.close_callback()
    p:set("bandwidth", "off") p:set("power_override", false) p:set("charger_only", false)

    -- reading goal on the Library screen
    p:set("goal_year", 10) p:set("goal_month", 2)
    local sf = dofile(tmp .. "/librarysync_status.lua")
    sf.dl2 = { status = "read", finished_at = os.time() }
    local wf = io.open(tmp .. "/librarysync_status.lua", "wb")
    wf:write("return " .. (function(t)
        local out = {}
        for k, v in pairs(t) do
            out[#out + 1] = string.format("[%q]={status=%q,finished_at=%d}", k, tostring(v.status), tonumber(v.finished_at or v.at or 0))
        end
        return "{" .. table.concat(out, ",") .. "}"
    end)(sf))
    wf:close()
    package.loaded["docsettings"] = nil
    p:browse() m = last("Menu")
    local gl = m.item_table[1].text
    assert(gl:find("🎯") and gl:find("of 10 books") and gl:find("of 2"), gl)
    m:onMenuSelect(m.item_table[1])
    eq(last("Menu").title, "Goals and reading stats")
    last("Menu").close_callback()

    -- new on this device: what syncs brought in, tap to open
    m:onMenuSelect(find(m, "New on this device"))
    local nm = last("Menu")
    eq(nm.title, "New on this device")
    local first = nm.item_table[1]
    assert(first.text and not first.text:find("Nothing yet"), "lists the downloads")
    local nopen = #opened
    first.callback()
    eq(#opened, nopen + 1, "opened in one tap")

    -- select several books: mark as finished, read later
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "All books"))
    m:onMenuSelect(find(m, "Select several books"))
    m:onMenuSelect(find(m, "Dune"))
    m:onMenuSelect(find(m, "Loose"))
    assert(find(m, "Dune").text:find("^☑") and find(m, "Emma").text:find("^☐"), "ticks shown")
    m:onMenuSelect(find(m, "Do with 2 ticked books"))
    local bd = last("ButtonDialog")
    assert(bd.title:find("2 books ticked"), bd.title)
    bd.buttons[1][1].callback()
    local stf = dofile(tmp .. "/librarysync_status.lua")
    eq(stf.dl1.status, "read") eq(stf.dl5.status, "read")
    assert(not find(m, "Dune").text:find("☑"), "selection ended")
    m:onMenuSelect(find(m, "Select several books"))
    m:onMenuSelect(find(m, "Tick all in this list"))
    m.onReturn()
    eq(m.title, "All books", "back leaves the selection, not the list")
    m.close_callback()

    -- reading stats: page turns while reading
    local r5 = LS:new{ ui = { menu = { registerToMainMenu = function() end },
        document = { file = tmp .. "/x.epub", getPageCount = function() return 10 end },
        doc_settings = { readSetting = function() end, saveSetting = function() end } } }
    r5:init()
    r5:onReaderReady()
    r5:onPageUpdate(1) r5:onPageUpdate(2) r5:onPageUpdate(3)
    r5:onCloseDocument()
    r5:showStats()
    assert(last("TextViewer").text:find("Today: 2 pages"), last("TextViewer").text)

    -- test connection: plain words, the version and what is supported
    done = true
    p:testConnection()
    eq(last("InfoMessage").text, "Checking the Library server…", "wait message while the check runs")
    table.remove(scheduled)()
    local tc = last("TextViewer")
    eq(tc.title, "Test connection: all good")
    assert(tc.text:find("✓ Signed in") and tc.text:find("version 1.33.0") and tc.text:find("Battery"), tc.text)
    assert(not last("InfoMessage") or last("InfoMessage").text ~= "Checking the Library server…", "wait message closed")
    -- the check wrote its steps to the debug log as it went
    local dl = io.open(tmp .. "/librarysync_debug.log", "rb"):read("*a")
    assert(dl:find("health: GET http://127.0.0.1:" .. port .. "/opds", 1, true) and dl:find("verdict all good", 1, true), dl)
    -- the check stops cleanly when the background process dies without a result
    fu.runInSubProcess = function() return 4243 end
    p:testConnection()
    table.remove(scheduled)()
    eq(last("TextViewer").title, "Test connection: failed")
    fu.runInSubProcess = function(f) f() return 4242 end
    -- save debug log: a file in the Library folder, passwords hidden, the path shown
    os.execute("mkdir -p '" .. tmp .. "/Library'")
    p:set("token", "sekrit-token")
    local crash = io.open(tmp .. "/crash.log", "wb") crash:write("old line\nlast crash line\n") crash:close()
    local lfs_stub = stubs["libs/libkoreader-lfs"]
    local attr0 = lfs_stub.attributes
    lfs_stub.attributes = function(path, what) if path == tmp .. "/Library" then return "directory" end return attr0(path, what) end
    local dpath = p:saveDebugLog()
    lfs_stub.attributes = attr0
    eq(dpath, tmp .. "/Library/librarysync-debug.txt")
    assert(last("InfoMessage").text:find(dpath, 1, true), last("InfoMessage").text)
    local rep = io.open(dpath, "rb"):read("*a")
    assert(rep:find("Plugin version: 2.5.1", 1, true) and rep:find("last crash line", 1, true)
        and rep:find("health: GET", 1, true), rep)
    assert(not rep:find("sekrit") and not rep:find('"pw"', 1, true) and rep:find("password = (set, hidden)", 1, true), rep)

    -- duplicates: the same book twice on the device, keep one
    local L = stubs["libs/libkoreader-lfs"]
    local real_attr = L.attributes
    L.dir = function(d)
        local h = assert(io.popen("ls -a '" .. d .. "' 2>/dev/null"))
        local names = {}
        for l in h:lines() do names[#names + 1] = l end
        h:close()
        local i = 0
        return function() i = i + 1 return names[i] end
    end
    L.attributes = function(path, what)
        local h = io.popen("[ -d '" .. path .. "' ] && echo directory || ([ -f '" .. path .. "' ] && echo file)")
        local mode = h:read("*l") h:close()
        return mode
    end
    local dupe = tmp .. "/Library/Dune.epub"
    local df = io.open(dupe, "wb") df:write("copy") df:close()
    p:showDuplicates()
    local dm = last("Menu")
    eq(dm.title, "Duplicates on this device")
    local dupe_item = find(dm, "Dune")
    assert(dupe_item.mandatory:find("2 copies"), dupe_item.mandatory)
    dm:onMenuSelect(dupe_item)
    local kd = last("ButtonDialog")
    local keep_btn
    for _i, row in ipairs(kd.buttons) do if row[1].text:find("Keep Dune.epub") then keep_btn = row[1] end end
    keep_btn.callback()
    last("ConfirmBox").ok_callback()
    assert(io.open(dupe), "kept")
    eq(io.open(key_path), nil, "the other copy deleted")
    local stx = dofile(tmp .. "/librarysync_state.lua")
    assert(stx.skip_dests[key_path], "not downloaded again")
    eq(sync_key(stx, dupe), "dl1", "the Library book lives in the copy kept")
    L.attributes, L.dir = real_attr, nil
end)
os.execute("pkill -f 'spec/server.py " .. port .. "'")
os.execute("rm -rf '" .. tmp .. "'")
if not ok then print("FAIL ui smoke\n     " .. tostring(err)) os.exit(1) end
print("ok   ui smoke: browse, download, back, settings, sync")
