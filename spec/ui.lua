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
    ["luasettings"] = { open = function() local d = {} return {
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
    eq(m.item_table[1].text, "Loose.epub", "newest first")
    eq(m.item_table[1].mandatory, "", "book outside folders is not synced")
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
    d.buttons[1][2].callback()
    eq(m.title, "Search: emma") find(m, "Emma")
    eq(requests, 0, "browsing makes no request")

    -- tapping a book that is on the device opens it
    m:onMenuSelect(find(m, "Emma"))
    eq(opened[1], tmp .. "/Library/Reads/Emma & Co.epub")

    -- a book not on the device: asks, then fetches just that one
    p:browse() m = last("Menu")
    m:onMenuSelect(find(m, "All books"))
    m:onMenuSelect(find(m, "Loose"))
    last("ConfirmBox").ok_callback()
    assert(io.open(tmp .. "/Library/Loose.epub"), "no folder: into the download folder")
    eq(find(m, "Loose").mandatory, "✓ ")

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
end)
os.execute("pkill -f 'spec/server.py " .. port .. "'")
os.execute("rm -rf '" .. tmp .. "'")
if not ok then print("FAIL ui smoke\n     " .. tostring(err)) os.exit(1) end
print("ok   ui smoke: browse, download, back, settings, sync")
