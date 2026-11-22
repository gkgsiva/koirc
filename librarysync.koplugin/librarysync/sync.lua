-- Incremental OPDS sync: walks the server's folders and downloads every book
-- into <base>/<folder name>/<file name>.
local ltn12 = require("ltn12")
local xml = require("librarysync/xml")
local util = require("librarysync/util")
local httpmod = require("librarysync/http")
local extras = require("librarysync/extras")

local M = {}

local ACQ = "http://opds-spec.org/acquisition"

local function is_acq(rel) return rel and rel:sub(1, #ACQ) == ACQ end

-- Fetch and parse one feed.
local function fetch_feed(cfg, url)
    local body = {}
    local code, hdrs = cfg.transport(url, cfg.headers, ltn12.sink.table(body))
    if not code then return nil, tostring(hdrs) end
    if code == 401 or code == 403 then return nil, "login refused (HTTP " .. code .. "): check the user name, password or token" end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) .. " for " .. url end
    local text = table.concat(body)
    if not text:find("<feed", 1, true) then return nil, "not an OPDS feed: " .. url end
    return xml.parse(text)
end
M.fetch_feed = fetch_feed

--- "Dune #2 - file.epub" when the book is in a series (unless the name already starts with it).
function M.series_name(fname, series, number)
    if not series or series == "" then return fname end
    if fname:lower():sub(1, #series) == series:lower() then return fname end
    local num = number and number ~= "" and (" #" .. number:gsub("%.0+$", "")) or ""
    return series .. num .. " - " .. fname
end

--- File format of an acquisition link: "epub", "kepub", "pdf"... (a "x.kepub.epub" is kepub).
function M.ext_of(path, mime)
    local low = tostring(path or ""):lower()
    if low:match("%.kepub%.epub$") or low:match("%.kepub$") or tostring(mime or ""):find("kepub", 1, true) then
        return "kepub"
    end
    return low:match("%.(%w+)$") or ""
end

-- Formats in the order taken when the preferred one is not offered.
M.FORMAT_ORDER = { "epub", "kepub", "azw3", "mobi", "pdf", "cbz", "fb2", "txt" }

--- Format preference of a Library folder: cfg.folder_formats[name], else cfg.format, else
-- "epub". "all" keeps every format the server offers.
function M.format_pref(cfg, folder)
    local p = folder and cfg.folder_formats and cfg.folder_formats[folder]
    if not p or p == "default" then p = cfg.format end
    return p or "epub"
end

--- One file per book, in the preferred format (or the first of FORMAT_ORDER the server has).
function M.pick_format(files, pref)
    if pref == "all" or #files <= 1 then return files end
    local rank = { [pref] = 0 }
    for i, e in ipairs(M.FORMAT_ORDER) do if rank[e] == nil then rank[e] = i end end
    local best, br = nil, math.huge
    for i, f in ipairs(files) do
        local r = (rank[f.ext] or 100) + i / 1000
        if r < br then best, br = f, r end
    end
    return { best }
end

--- The downloadable files of one OPDS book entry: { {key=, name=, url=, size=, series=, number=} }.
function M.book_files(cfg, page_url, book)
    local out = {}
    local sname, snum = xml.series(book)
    local folders = xml.folders(book)
    for _, link in ipairs(book.links) do
        if is_acq(link.rel) then
            local path = link.href:gsub("[?#].*$", "")
            local id = path:match("/files/(%d+)")
            local fname = util.url_decode(path:match("([^/]+)$") or "")
            if fname == "" or fname:match("^%d+$") then fname = book.title end
            if cfg.series_in_names ~= false then fname = M.series_name(fname, sname, snum) end
            out[#out + 1] = {
                key = id and ("dl" .. id) or path,
                name = util.safe_name(fname, "book"),
                url = util.resolve(page_url, link.href),
                size = tonumber(link.length),
                series = sname, number = snum, title = book.title, folders = folders,
                ext = M.ext_of(path, link.type),
            }
        end
    end
    return out
end

--- List the server's folders and the files in each.
-- Returns { {name=, files={ {key=, name=, url=, size=} }} } or nil, err.
local function read_folder(cfg, folder, progress)
    local page, seen = folder.url, {}
    while page and not seen[page] do
        seen[page] = true
        if progress and progress("Reading folder " .. folder.name) == false then return nil, "cancelled" end
        local feed, perr = fetch_feed(cfg, page)
        if not feed then return nil, perr end
        folder.entries = folder.entries or {}
        for _, book in ipairs(feed.entries) do
            folder.entries[#folder.entries + 1] = { entry = book, page = page }
            local pref = M.format_pref(cfg, folder.name)
            for _, file in ipairs(M.pick_format(M.book_files(cfg, page, book), pref)) do
                folder.files[#folder.files + 1] = file
            end
        end
        local nxt = xml.link(feed, "next")
        page = nxt and util.resolve(page, nxt.href) or nil
    end
    return folder
end

-- What kind of Library folder a /opds/folders entry is, from its text ("List · 5 books").
local KINDS = { ["Series"] = "series", ["List"] = "list", ["Your folder"] = "own",
                ["Collection"] = "collection", ["Files in no other folder"] = "others" }
function M.folder_kind(content)
    local label = tostring(content or ""):match("^(.-)%s+·") or ""
    return KINDS[label]
end

function M.crawl(cfg, progress)
    if cfg.only then
        -- one folder (the browser's "Download everything in this folder"): no need to walk the root
        local folder, err = read_folder(cfg, { name = cfg.only.name, url = cfg.only.url, files = {} }, progress)
        if not folder then return nil, err end
        return { folder }
    end
    local root = cfg.server .. "/opds"
    local rootfeed, err = fetch_feed(cfg, root)
    if not rootfeed then return nil, err end
    -- Find the "Folders" subsection by its path, falling back to the known one.
    local folders_url = cfg.server .. "/opds/folders"
    for _, e in ipairs(rootfeed.entries) do
        local l = xml.link(e, "subsection")
        if l and l.href:match("/folders/?$") then folders_url = util.resolve(root, l.href) end
    end
    local ff, ferr = fetch_feed(cfg, folders_url)
    if not ff then return nil, ferr end
    local out = {}
    for _, e in ipairs(ff.entries) do
        local l = xml.link(e, "subsection")
        if l then
            local folder = { name = e.title, files = {}, url = util.resolve(folders_url, l.href),
                             kind = M.folder_kind(e.content) }
            if cfg.skip_folders and cfg.skip_folders[e.title] then
                folder.skipped = true  -- listed (the browser shows it), not read or downloaded
            else
                local rerr
                folder, rerr = read_folder(cfg, folder, progress)
                if not folder then return nil, rerr end
            end
            out[#out + 1] = folder
        end
    end
    return out
end

--- One catalog book from an OPDS entry (nil when it has no file).
function M.entry_book(cfg, page, e)
    local files = M.book_files(cfg, page, e)
    if #files == 0 then return nil end
    local sname, snum = xml.series(e)
    local cover = xml.link(e, "http://opds-spec.org/image")
    return {
        id = e.id ~= "" and e.id or e.title, title = e.title, authors = e.authors or {}, updated = e.updated or "",
        series = sname, number = snum, folders = xml.folders(e), files = files,
        progress = e.progress, last_read = util.iso_time(e.last_read), added = e.added,
        status = (e.status and e.status ~= "") and e.status or nil,
        cover = cover and cover.href and util.resolve(page, cover.href) or nil,
    }
end

--- Read every page of a book feed: list of parsed entries, or nil, err.
local function read_all(cfg, url, progress, label)
    local out, page, seen = {}, url, {}
    while page and not seen[page] do
        seen[page] = true
        if progress and progress(label) == false then return nil, "cancelled" end
        local feed, err = fetch_feed(cfg, page)
        if not feed then return nil, err end
        for _, e in ipairs(feed.entries) do out[#out + 1] = { entry = e, page = page } end
        local nxt = xml.link(feed, "next")
        page = nxt and util.resolve(page, nxt.href) or nil
    end
    return out
end

--- Build the on-device copy of the catalog that the Library browser shows (it never asks the
-- server itself). folders: the crawl, for folder order and links.
-- Returns { synced_at, books = { {id, title, authors, updated, series, number, folders, files} },
--           reading = { [id] = true }, folders = { {name, url} } }.
function M.build_catalog(cfg, folders, progress)
    local cat = { synced_at = os.time(), books = {}, reading = {}, folders = {} }
    for _, f in ipairs(folders) do cat.folders[#cat.folders + 1] = { name = f.name, url = f.url, kind = f.kind } end
    local summaries = {}
    local function add(list)
        local seen = {}
        for _, b in ipairs(cat.books) do seen[b.id] = true end
        for _, it in ipairs(list) do
            local e = it.entry
            local b = M.entry_book(cfg, it.page, e)
            if b and not seen[b.id] then
                seen[b.id] = true
                if e.summary and e.summary ~= "" then summaries[b.id] = e.summary end
                cat.books[#cat.books + 1] = b
            end
        end
    end
    local all = read_all(cfg, cfg.server .. "/opds/all", progress, "Reading the catalog")
    if all then
        add(all)
        cat.complete = true  -- every book on the server (cleanup relies on it)
    else
        -- older server without /opds/all: the books in folders
        local list = {}
        for _, f in ipairs(folders) do
            for _, e in ipairs(f.entries or {}) do list[#list + 1] = e end
        end
        add(list)
    end
    cat.reading = M.read_reading(cfg, progress, cat) or {}
    cat.newest = ""
    for _, b in ipairs(cat.books) do if (b.updated or "") > cat.newest then cat.newest = b.updated end end
    return cat, summaries
end

--- Books started on the server ("Continue reading"): set of ids. With cat, also brings the
-- progress and last-read time of those books up to date in it (a quick sync sees no others).
function M.read_reading(cfg, progress, cat)
    local reading = read_all(cfg, cfg.server .. "/opds/reading", progress, "Reading the catalog")
    if not reading then return nil end
    local out, index = {}, {}
    for i, b in ipairs(cat and cat.books or {}) do index[b.id] = i end
    for _, it in ipairs(reading) do
        local id = it.entry.id ~= "" and it.entry.id or it.entry.title
        out[id] = true
        local b = index[id] and cat.books[index[id]]
        if b then
            b.progress = it.entry.progress or b.progress
            b.last_read = util.iso_time(it.entry.last_read) or b.last_read
            if it.entry.status and it.entry.status ~= "" then b.status = it.entry.status end
        end
    end
    return out
end

--- Quick sync: only the books added (or given a new file) since the last sync, found at the
-- top of /opds/recent. Updates the saved catalog in place and returns folders for M.plan,
-- or nil when a full sync is needed (no catalog yet). Books moved between folders without a
-- new file, and books removed from the server, are only seen by a full sync.
function M.quick_crawl(cfg, progress)
    local cat = cfg.catalog_path and util.load_table(cfg.catalog_path)
    if not (cat and cat.books and cat.newest and cat.newest ~= "") then return nil end
    local new, page, seen = {}, cfg.server .. "/opds/recent", {}
    while page and not seen[page] do
        seen[page] = true
        if progress and progress("Looking for new books") == false then return nil, "cancelled" end
        local feed, err = fetch_feed(cfg, page)
        if not feed then return nil, err end
        local older = false
        for _, e in ipairs(feed.entries) do
            if (e.updated or "") <= cat.newest then older = true break end
            new[#new + 1] = { entry = e, page = page }
        end
        if older then break end
        local nxt = xml.link(feed, "next")
        page = nxt and util.resolve(page, nxt.href) or nil
    end
    -- merge into the catalog
    local index = {}
    for i, b in ipairs(cat.books) do index[b.id] = i end
    local summaries = cfg.summaries_path and util.load_table(cfg.summaries_path) or {}
    local by_folder, order = {}, {}
    for _, it in ipairs(new) do
        local e = it.entry
        local b = M.entry_book(cfg, it.page, e)
        if b then
            local id, files = b.id, b.files
            if index[id] then cat.books[index[id]] = b else cat.books[#cat.books + 1] = b index[id] = #cat.books end
            if e.summary and e.summary ~= "" then summaries[id] = e.summary end
            if (b.updated or "") > cat.newest then cat.newest = b.updated end
            for _, fname in ipairs(b.folders) do
                if not (cfg.skip_folders and cfg.skip_folders[fname]) then
                    if not by_folder[fname] then by_folder[fname] = {} order[#order + 1] = fname end
                    for _, f in ipairs(M.pick_format(files, M.format_pref(cfg, fname))) do table.insert(by_folder[fname], f) end
                end
            end
        end
    end
    -- keep folder names known to the catalog (new folders show after the next full sync)
    local known = {}
    for _, f in ipairs(cat.folders or {}) do known[f.name] = true end
    for _, fname in ipairs(order) do
        if not known[fname] then
            cat.folders[#cat.folders + 1] = { name = fname }
            known[fname] = true
        end
    end
    cat.reading = M.read_reading(cfg, progress, cat) or cat.reading
    cat.synced_at = os.time()
    util.save_table(cfg.catalog_path, cat)
    if cfg.summaries_path then util.save_table(cfg.summaries_path, summaries) end
    local folders = {}
    for _, fname in ipairs(order) do folders[#folders + 1] = { name = fname, files = by_folder[fname] } end
    return folders, nil, #new
end

--- Turn the crawl into download items: one per server file, with every local place it belongs.
-- Folder and file names are made unique so two different files never share a path.
function M.plan(folders, base)
    local items, by_key, taken = {}, {}, {}
    local used_dirs = {}
    for _, f in ipairs(folders) do
        local dir = util.safe_name(f.name, "Folder")
        local low = dir:lower()
        if used_dirs[low] and used_dirs[low] ~= f.name then
            dir = dir .. " (" .. ((f.url or ""):match("/(%d+)/?$") or tostring(#items)) .. ")"
        end
        used_dirs[dir:lower()] = f.name
        for _, file in ipairs(f.files) do
            local it = by_key[file.key]
            if not it then
                it = { key = file.key, url = file.url, size = file.size, name = file.name, dests = {}, folder = f.name }
                by_key[file.key] = it
                items[#items + 1] = it
            end
            local path = base .. "/" .. dir .. "/" .. file.name
            if taken[path:lower()] and taken[path:lower()] ~= file.key then
                local stem, ext = file.name:match("^(.*)(%.[^.]+)$")
                stem, ext = stem or file.name, ext or ""
                path = base .. "/" .. dir .. "/" .. stem .. " (" .. file.key:gsub("^dl", "") .. ")" .. ext
            end
            if not taken[path:lower()] then
                taken[path:lower()] = file.key
                it.dests[#it.dests + 1] = path
            end
        end
    end
    return items
end

-- Download url to dest through dest..".part"; resumes with a Range request when it can.
-- Returns true, or nil + error.  The part file is kept after a failure so the next run resumes.
local function download(cfg, item, dest, tick)
    local part = dest .. ".part"
    local have = util.file_size(part) or 0
    local headers = {}
    for k, v in pairs(cfg.headers) do headers[k] = v end
    local target = part
    if have > 0 then
        headers.Range = "bytes=" .. have .. "-"
        target = part .. ".new"
    end
    local f, ferr = io.open(target, "wb")
    if not f then return nil, "cannot write " .. target .. ": " .. tostring(ferr) end
    local received = 0
    local cancelled, write_err = false, nil
    local function sink(chunk, err)
        if chunk == nil then return 1 end
        if chunk == "" then return 1 end
        local okw, werr = f:write(chunk)
        if not okw then write_err = tostring(werr) return nil, write_err end
        received = received + #chunk
        if tick and tick(have + received) == false then cancelled = true return nil, "cancelled" end
        return 1
    end
    local code, hdrs = cfg.transport(item.url, headers, sink)
    f:close()
    if write_err then
        -- disk full or card removed: drop the new bytes, keep the earlier part for a later resume
        os.remove(target)
        if target == part then os.remove(part) end
        return nil, "cannot write " .. dest .. " (" .. write_err .. "): is the storage full?"
    end
    if cancelled then
        if have > 0 then
            local g = io.open(part, "ab")
            local n = io.open(target, "rb")
            if g and n then g:write(n:read("*a")) end
            if g then g:close() end
            if n then n:close() end
            os.remove(target)
        end
        return nil, "cancelled"
    end
    if not code then
        -- keep what arrived so the next run resumes from it
        if have > 0 then
            local n = io.open(target, "rb")
            local g = io.open(part, "ab")
            if n and g then g:write(n:read("*a")) end
            if n then n:close() end
            if g then g:close() end
            os.remove(target)
        end
        return nil, tostring(hdrs)
    end
    if code == 416 and have > 0 then
        -- the part file is already the whole thing (or stale): start again from scratch
        os.remove(target) os.remove(part)
        return nil, "stale partial file removed, will retry"
    end
    if code == 206 and have > 0 then
        local g = io.open(part, "ab")
        local n = io.open(target, "rb")
        if not (g and n) then
            if g then g:close() end
            if n then n:close() end
            os.remove(target)
            return nil, "cannot write " .. part
        end
        g:write(n:read("*a")) g:close() n:close()
        os.remove(target)
    elseif code == 200 then
        if have > 0 then os.remove(part) os.rename(target, part) end
    else
        os.remove(target)
        if code == 401 or code == 403 then return nil, "login refused (HTTP " .. code .. ")" end
        if code == 404 then os.remove(part) return nil, "file no longer on the server (HTTP 404)" end
        return nil, "HTTP " .. tostring(code)
    end
    local size = util.file_size(part) or 0
    local expect = item.size or tonumber(hdrs and (hdrs["content-length"] or hdrs["Content-Length"]))
    if code == 206 then expect = item.size end
    if size == 0 then os.remove(part) return nil, "empty file received" end
    if expect and size ~= expect then
        if size > expect then os.remove(part) end
        return nil, string.format("incomplete (%d of %d bytes)", size, expect)
    end
    os.remove(dest)
    if not os.rename(part, dest) then return nil, "cannot move file into place" end
    return true, size
end

local function done(state, item, dest)
    local rec = state.files[item.key]
    local size = util.file_size(dest)
    if not size or size == 0 then return false end
    if item.size and size ~= item.size then return false end
    return rec ~= nil and rec[dest] == size or (item.size ~= nil and size == item.size)
end

M.done = done

--- Local path of a file shown in Library folder `dir` (nil = straight in the download folder).
function M.dest(cfg, dir, file)
    if not dir or dir == "" then return cfg.base .. "/" .. file.name end
    return cfg.base .. "/" .. util.safe_name(dir, "Folder") .. "/" .. file.name
end

local function present(path, file)
    local size = util.file_size(path)
    return size and size > 0 and (not file.size or file.size == size)
end

-- Load the state file, apply fn(state), save it again. Re-reading first keeps what another
-- writer (a background sync, a single download) saved in the meantime.
local function update_state(cfg, fn)
    if not cfg.state_path then return end
    local st = util.load_table(cfg.state_path) or {}
    st.files = st.files or {}
    fn(st)
    util.save_table(cfg.state_path, st)
end
M.update_state = update_state

--- Download one file into its folder (and nothing else). Returns path or nil, err.
-- Used by the browser; records the file in the sync state so Sync now skips it.
function M.download_one(cfg, dir, file, progress, dest)
    cfg.transport = cfg.transport or httpmod.get
    cfg.headers = cfg.headers or httpmod.auth_headers(cfg)
    dest = dest or M.dest(cfg, dir, file)
    util.mkdirs(dest:match("^(.*)/[^/]*$"))
    local ok, e
    for _ = 1, 2 do
        ok, e = download(cfg, file, dest, progress)
        if ok or e == "cancelled" then break end
    end
    if not ok then return nil, e end
    update_state(cfg, function(st)
        local rec = st.files[file.key] or {}
        rec[dest] = util.file_size(dest)
        st.files[file.key] = rec
        if st.removed then st.removed[file.key] = nil end  -- fetched on purpose: sync it again
    end)
    return dest
end

--- Where a file shown in folder `dir` lives locally, and whether it is already there.
function M.local_path(cfg, dir, file)
    local dest = M.dest(cfg, dir, file)
    return dest, present(dest, file) and true or false
end

--- An existing local copy of a file seen anywhere in the catalog (Recently added, Series...):
-- a path the sync state recorded for it, else its place in any of its Library folders.
-- state: a loaded state table (optional; pass one when checking many files).
function M.find_local(cfg, file, state)
    local rec = state and state.files and state.files[file.key]
    if rec then
        for path in pairs(rec) do
            if present(path, file) then return path end
        end
    end
    for _, dir in ipairs(file.folders or {}) do
        local p = M.dest(cfg, dir, file)
        if present(p, file) then return p end
    end
end

--- Library download id of a file key ("dl12" -> 12).
local function download_id(key) return tonumber((key or ""):match("^dl(%d+)$")) end

--- Server file key of a local book path, from the sync state (nil if the plugin did not fetch it).
function M.key_for_path(state, path)
    for key, rec in pairs(state and state.files or {}) do
        if rec[path] then return key end
    end
end

--- Send the reading positions saved while reading ({ [key] = {percent=, at=, tz=} } in
-- cfg.positions_path) to the Library server, which passes them on to Hardcover.
-- Sent ones are removed; ones that fail stay for the next sync. Returns the number sent.
function M.push_positions(cfg, progress)
    local pending = util.load_table(cfg.positions_path)
    if not pending or next(pending) == nil then return 0 end
    local sent = {}
    for key, p in pairs(pending) do
        local id = download_id(key)
        if id and type(p) == "table" and p.percent then
            if progress and progress("Sending reading progress") == false then break end
            local body = string.format('{"percent": %.4f, "at": %d, "tz": %d}', p.percent, p.at or os.time(), p.tz or 0)
            local code = (cfg.send or httpmod.send)("PUT", cfg.server .. "/api/downloads/" .. id .. "/position", cfg.headers, body)
            if code == 200 or code == 404 then sent[key] = p.at end  -- 404: gone from the server
        elseif not id then
            sent[key] = type(p) == "table" and p.at or true
        end
    end
    -- re-read: the reader may have saved a newer place meanwhile; keep that one
    local now = util.load_table(cfg.positions_path) or {}
    local n = 0
    for key, at in pairs(sent) do
        if now[key] and (now[key].at == at or at == true) then now[key] = nil end
        n = n + 1
    end
    util.save_table(cfg.positions_path, now)
    -- remember when each place was sent: a place read on another device is only newer than that
    update_state(cfg, function(st)
        st.sent_at = st.sent_at or {}
        for key, at in pairs(sent) do if type(at) == "number" then st.sent_at[key] = at end end
    end)
    return n
end

M.FINISHED = 0.98
M.PULL_MAX = 100

--- Two-way progress: fetch the server's reading place of the downloaded books that were read
-- somewhere since we last looked (the catalog's last-read time says which), and save them in
-- cfg.remote_path as { [key] = {percent=, at=} }. The reader offers to jump there when the book
-- opens. Accounts that may only use OPDS get the catalog's per-book progress instead.
-- Returns the number of books with a newer place.
function M.pull_positions(cfg, cat, progress)
    if not (cfg.remote_path and cat and cat.books) then return 0 end
    local state = (cfg.state_path and util.load_table(cfg.state_path)) or {}
    local files, seen = state.files or {}, state.remote_seen or {}
    local remote = util.load_table(cfg.remote_path) or {}
    local n, asked, opds_only = 0, 0, false
    local newseen = {}
    for _, b in ipairs(cat.books) do
        if b.last_read then
            for _, f in ipairs(b.files or {}) do
                local id = download_id(f.key)
                if id and files[f.key] and b.last_read > (seen[f.key] or 0) and asked < M.PULL_MAX then
                    if progress and progress("Getting reading progress") == false then break end
                    local percent, at
                    if not opds_only then
                        asked = asked + 1
                        local out = {}
                        local code = cfg.transport(cfg.server .. "/api/downloads/" .. id .. "/position",
                            cfg.headers, ltn12.sink.table(out))
                        local body = table.concat(out)
                        if code == 200 then
                            percent, at = util.json_number(body, "percent"), util.json_number(body, "updated_at")
                        elseif code == 403 then
                            opds_only = true
                        end
                    end
                    if opds_only then percent, at = b.progress, b.last_read end
                    if percent and at then
                        local old = remote[f.key]
                        if not old or at > (old.at or 0) then
                            remote[f.key] = { percent = percent, at = math.floor(at) }
                            n = n + 1
                        end
                    end
                    if percent or opds_only then newseen[f.key] = b.last_read end
                end
            end
        end
    end
    if next(newseen) then
        util.save_table(cfg.remote_path, remote)
        update_state(cfg, function(st)
            st.remote_seen = st.remote_seen or {}
            for k, v in pairs(newseen) do st.remote_seen[k] = v end
        end)
    end
    return n
end

--- Per-folder rules (cfg.folder_rules[name] = "unread" | N): which files of each ruled folder
-- may be downloaded, and the downloaded-book candidates past the newest N.
-- "unread": books not finished. N: the N books added last.
-- Returns allowed[folder] = { [key] = true }, over[folder] = { {file=, book=} }.
function M.rule_sets(rules, cat)
    local allowed, over = {}, {}
    if not (rules and cat and cat.books) then return allowed, over end
    for folder, rule in pairs(rules) do
        local books = {}
        for _, b in ipairs(cat.books) do
            for _, f in ipairs(b.folders or {}) do
                if f == folder then books[#books + 1] = b break end
            end
        end
        local set, extra = {}, {}
        local n = tonumber(rule)
        if rule == "unread" then
            for _, b in ipairs(books) do
                if (b.progress or 0) < M.FINISHED then
                    for _, f in ipairs(b.files or {}) do set[f.key] = true end
                end
            end
        elseif n then
            table.sort(books, function(a, b)
                local x, y = a.added or a.updated or "", b.added or b.updated or ""
                if x ~= y then return x > y end
                return (a.title or "") < (b.title or "")
            end)
            for i, b in ipairs(books) do
                for _, f in ipairs(b.files or {}) do
                    if i <= n then set[f.key] = true else extra[#extra + 1] = { file = f, book = b } end
                end
            end
        else
            set = nil
        end
        if set then allowed[folder], over[folder] = set, extra end
    end
    return allowed, over
end

--- Apply the folder rules to a crawl (in place). Files not allowed are left out.
function M.apply_rules(folders, allowed)
    for _, f in ipairs(folders) do
        local set = allowed[f.name]
        if set then
            local keep = {}
            for _, file in ipairs(f.files or {}) do
                if set[file.key] then keep[#keep + 1] = file end
            end
            f.files = keep
        end
    end
end

--- Books on the device that a sync would remove, for the sync preview: books gone from the
-- server (or from that folder), and books that fell out of a "newest N" folder and were never
-- started. Only books the plugin downloaded; paths in state.kept (unticked before) are left.
-- Returns { {path=, name=, size=, why=} }.
function M.removals(cfg, cat, state, over)
    local out, seen = {}, {}
    local kept = state.kept or {}
    local paths = M.cleanup_candidates(cfg, cat, state) or {}
    for _, p in ipairs(paths) do
        if not kept[p] then
            seen[p] = true
            out[#out + 1] = { path = p, name = p:match("([^/]+)$"), size = util.file_size(p), why = "gone" }
        end
    end
    for folder, list in pairs(over or {}) do
        for _, o in ipairs(list) do
            local p = M.dest(cfg, folder, o.file)
            local rec = state.files and state.files[o.file.key]
            if rec and rec[p] and not seen[p] and not kept[p] and (o.book.progress or 0) == 0
               and not o.book.last_read and not (cfg.started and cfg.started(p)) and util.file_size(p) then
                seen[p] = true
                out[#out + 1] = { path = p, name = o.file.name, size = util.file_size(p), why = "old", folder = folder }
            end
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

--- Read-later queue (cfg.queue_path): { [key] = {file=, dir=, title=, at=} }, filled on the
-- device (also offline) and downloaded by the next sync.
function M.queue_add(cfg, dir, file, title)
    local q = util.load_table(cfg.queue_path) or {}
    q[file.key] = { file = file, dir = dir, title = title or file.name, at = os.time() }
    util.save_table(cfg.queue_path, q)
end

function M.queue_remove(cfg, key)
    local q = util.load_table(cfg.queue_path) or {}
    q[key] = nil
    util.save_table(cfg.queue_path, q)
end

-- Queue entries as download items (added to items in place, merged by key).
local function add_queue(cfg, items)
    local q = cfg.queue_path and util.load_table(cfg.queue_path)
    if not q then return 0 end
    local by = {}
    for _, it in ipairs(items) do by[it.key] = it end
    local n = 0
    for key, e in pairs(q) do
        if type(e) == "table" and e.file then
            local dest = e.path or M.dest(cfg, e.dir, e.file)
            local it = by[key]
            if not it then
                it = { key = key, url = e.file.url, size = e.file.size, name = e.file.name, dests = {}, folder = e.dir }
                items[#items + 1] = it
                by[key] = it
            end
            it.queued = true
            local has = false
            for _, d in ipairs(it.dests) do if d == dest then has = true end end
            if not has then table.insert(it.dests, 1, dest) end
            n = n + 1
        end
    end
    return n
end

--- Books the plugin downloaded that the server no longer has in that place: the book was
-- removed from the server, or from that folder. Only paths in the sync state are considered,
-- so files you added yourself are never listed. Returns a list of paths, or nil, reason.
function M.cleanup_candidates(cfg, cat, state)
    if not (cat and cat.complete) then return nil, "run a full sync first" end
    local expected = {}
    for _, b in ipairs(cat.books) do
        for _, f in ipairs(b.files or {}) do
            expected[M.dest(cfg, nil, f)] = true
            for _, dir in ipairs(b.folders or {}) do expected[M.dest(cfg, dir, f)] = true end
            -- names made unique by the sync ("x (12).epub") belong to the book too
            local stem, ext = f.name:match("^(.*)(%.[^.]+)$")
            for _, dir in ipairs(b.folders or {}) do
                expected[cfg.base .. "/" .. util.safe_name(dir, "Folder") .. "/" .. (stem or f.name)
                    .. " (" .. f.key:gsub("^dl", "") .. ")" .. (ext or "")] = true
            end
        end
    end
    local out = {}
    for _, rec in pairs(state and state.files or {}) do
        for path in pairs(rec) do
            if not expected[path] and util.file_size(path) then out[#out + 1] = path end
        end
    end
    table.sort(out)
    return out
end

--- Delete the given paths and forget them in the sync state. Returns the number removed.
function M.cleanup(cfg, paths)
    local gone = {}
    local n = 0
    for _, p in ipairs(paths) do
        if os.remove(p) or not util.file_size(p) then gone[p] = true n = n + 1 end
    end
    update_state(cfg, function(st)
        for key, rec in pairs(st.files) do
            for p in pairs(gone) do rec[p] = nil end
            if next(rec) == nil then st.files[key] = nil end
        end
    end)
    return n
end

--- Items of a plan that still need a download (some place missing), as a key set.
function M.todo(state, items)
    local out = {}
    for _, it in ipairs(items) do
        for _, d in ipairs(it.dests) do
            if not done(state, it, d) then out[it.key] = true break end
        end
    end
    return out
end

local LOG_KEEP = 10

--- Add one sync to the log (cfg.log_path): newest first, the last LOG_KEEP kept.
function M.write_log(cfg, entry)
    if not cfg.log_path then return end
    local log = util.load_table(cfg.log_path) or {}
    table.insert(log, 1, entry)
    while #log > LOG_KEEP do table.remove(log) end
    util.save_table(cfg.log_path, log)
end

--- Run a sync.
-- cfg: server, auth/username/password/token, base, transport (optional), state_path,
--      progress(text, done, total) -> false to stop.
--   Optional: catalog_path, summaries_path, positions_path (push), remote_path (pull),
--   folder_rules, skip_folders, queue_path (read later), plan_path + preview_min (stop with
--   res.preview when that many books would download, or anything would be removed),
--   use_plan (download the saved plan: exclude = {key=true} unticked, remove = {paths}),
--   retry (with use_plan: only the unfinished and failed items, and the queue), log_path.
-- Returns { downloaded, skipped, failed = { {name=, error=} }, total, cancelled, error, ... }.
function M.run(cfg)
    cfg.transport = cfg.transport or httpmod.get
    cfg.headers = cfg.headers or httpmod.auth_headers(cfg)
    local progress = cfg.progress or function() end
    local res = { downloaded = 0, skipped = 0, failed = {}, total = 0, added = {}, removed = {},
                  kind = cfg.retry and "retry" or cfg.use_plan and "reviewed" or cfg.only and "folder"
                      or cfg.quick and "quick" or "full", started_at = os.time(), auto = cfg.auto or nil }
    local state = (cfg.state_path and util.load_table(cfg.state_path)) or {}
    state.files = state.files or {}
    local items, removals = nil, {}
    local cat
    res.auto_removed = {}
    local function finish()
        res.finished_at = os.time()
        if not res.preview and not cfg.push_only then
            M.write_log(cfg, {
                at = res.finished_at, kind = res.kind, auto = res.auto, added = res.added, removed = res.removed,
                failed = res.failed, skipped = res.skipped, error = res.error, cancelled = res.cancelled,
                storage_full = res.storage_full, positions = res.positions, pulled = res.pulled,
                declined = res.declined, waiting_removals = res.waiting_removals, new_books = res.new_books,
                statuses = res.statuses, notes = res.notes, status_pulled = res.status_pulled,
                auto_removed = res.auto_removed, meta = res.meta_paths and #res.meta_paths or nil,
                next_queued = res.next_queued, status_unsupported = res.status_unsupported,
            })
        end
        return res
    end

    -- Book status, rating, highlights and notes read from KOReader's data, then everything
    -- waiting is sent: places, statuses and ratings, highlights and notes.
    local function push_all(only)
        local okc, cerr = pcall(extras.collect, cfg, state, only)
        if not okc then res.collect_error = tostring(cerr) end
        if cfg.positions_path then res.positions = M.push_positions(cfg, progress) end
        if cfg.send_status ~= false and cfg.status_path then
            local ok, n, unsupported = pcall(extras.push_status, cfg, progress)
            if ok then res.statuses, res.status_unsupported = n, unsupported or nil end
        end
        if cfg.notes_path then
            local ok, n = pcall(extras.push_notes, cfg, progress)
            res.notes = ok and n or 0
        end
    end

    if cfg.push_only then
        -- a book was just closed: send what changed, nothing else
        res.kind = "push"
        push_all(cfg.only_paths)
        return finish()
    end

    if cfg.use_plan then
        local plan = cfg.plan_path and util.load_table(cfg.plan_path) or {}
        cat = cfg.catalog_path and util.load_table(cfg.catalog_path) or nil
        items = {}
        local failed, pending = state.failed or {}, state.pending or {}
        for _, it in ipairs(plan.items or {}) do
            local want = not (cfg.exclude and cfg.exclude[it.key])
            if want and cfg.retry then
                want = pending[it.key] or (failed[it.key] and (failed[it.key].tries or 0) < 5)
            end
            if want then items[#items + 1] = it end
        end
        add_queue(cfg, items)
        removals = cfg.remove or {}
    else
        if not cfg.only then
            -- books marked finished in KOReader (also from the file browser) go out as 100%
            if cfg.collect_finished then pcall(cfg.collect_finished, state) end
            push_all()
        end
        local folders, err, quick_new
        if cfg.quick and not cfg.only then
            folders, err, quick_new = M.quick_crawl(cfg, progress)
            if folders then res.quick, res.new_books = true, quick_new end
        end
        if not folders and err == nil then folders, err = M.crawl(cfg, progress) end
        if not folders then
            res.error = err
            res.cancelled = err == "cancelled"
            return finish()
        end
        if not cfg.only and not res.quick and cfg.catalog_path then
            local summaries
            cat, summaries = M.build_catalog(cfg, folders, progress)
            util.save_table(cfg.catalog_path, cat)
            if cfg.summaries_path then util.save_table(cfg.summaries_path, summaries or {}) end
        elseif not cfg.only and cfg.catalog_path then
            cat = util.load_table(cfg.catalog_path)
        end
        local over = {}
        if not cfg.only and cat then
            local allowed
            allowed, over = M.rule_sets(cfg.folder_rules, cat)
            M.apply_rules(folders, allowed)
            local okp, pulled = pcall(M.pull_positions, cfg, cat, progress)
            res.pulled = okp and pulled or 0
            state = util.load_table(cfg.state_path or "") or state  -- push/pull saved to it
            state.files = state.files or {}
            local okn, queued = pcall(extras.next_requests, cfg, cat, state, progress)
            res.next_queued = okn and queued and #queued > 0 and queued or nil
            if not okn then res.next_error = tostring(queued) end
            -- finished books past "Remove finished books after N days" (kept on the undo list)
            local okr, names = pcall(extras.auto_remove, cfg, cat, state)
            if okr then for _, n in ipairs(names or {}) do res.auto_removed[#res.auto_removed + 1] = n end end
        end
        items = M.plan(folders, cfg.base)
        if not cfg.only then
            -- what an earlier sync left unfinished or failed (a quick sync would not see it again)
            local old = cfg.plan_path and util.load_table(cfg.plan_path)
            if old and old.items then
                local have = {}
                for _, it in ipairs(items) do have[it.key] = true end
                for _, it in ipairs(old.items) do
                    if not have[it.key] and ((state.pending or {})[it.key] or (state.failed or {})[it.key]) then
                        items[#items + 1] = it
                        have[it.key] = true
                    end
                end
            end
            add_queue(cfg, items)
            if cat then removals = M.removals(cfg, cat, state, over) end
            local todo = M.todo(state, items)
            if cfg.plan_path then
                local list = {}
                local gone = state.removed or {}
                for _, it in ipairs(items) do
                    if todo[it.key] and not (gone[it.key] and not it.queued) then
                        list[#list + 1] = it
                        it.declined = (state.declined or {})[it.key] and not it.queued or nil
                    end
                end
                util.save_table(cfg.plan_path, { at = os.time(), items = list, removals = removals })
                local count = 0
                for _, it in ipairs(list) do if not it.declined then count = count + 1 end end
                if cfg.preview_min and cfg.preview_min > 0 and (count >= cfg.preview_min or #removals > 0) then
                    res.preview, res.preview_count, res.preview_removals = true, count, #removals
                    return finish()
                end
            end
            -- nothing to review: never delete without asking
            res.waiting_removals = #removals > 0 and #removals or nil
            removals = {}
        end
    end
    -- unticked before, or removed as finished (and not queued since): not downloaded
    local declined, gone = state.declined or {}, state.removed or {}
    local kept = {}
    for _, it in ipairs(items) do
        if gone[it.key] and not it.queued then
            -- a finished book removed from the device (see the undo list)
        elseif declined[it.key] and not it.queued then
            res.declined = (res.declined or 0) + 1
        else
            kept[#kept + 1] = it
        end
    end
    items = kept
    res.total = #items
    util.mkdirs(cfg.base)

    local todo_keys = M.todo(state, items)
    local track = not cfg.only
    if track then
        update_state(cfg, function(st)
            st.pending = st.pending or {}
            for k in pairs(todo_keys) do st.pending[k] = true end
        end)
    end
    local changed = {}
    local finished_keys, failed_now = {}, {}
    local function save(finished)
        update_state(cfg, function(st)
            for k in pairs(changed) do st.files[k] = state.files[k] end
            if track then
                st.pending = st.pending or {}
                st.failed = st.failed or {}
                for k in pairs(finished_keys) do st.pending[k] = nil st.failed[k] = nil end
                for k, e in pairs(failed_now) do
                    st.pending[k] = nil
                    local old = st.failed[k] or {}
                    st.failed[k] = { name = e.name, error = e.error, tries = (old.tries or 0) + 1, at = os.time() }
                end
            end
            if finished then st.last_sync = os.time() end
        end)
        changed, finished_keys, failed_now = {}, {}, {}
    end

    local downloaded_queue = {}
    for i, it in ipairs(items) do
        local todo, have = {}, nil
        for _, d in ipairs(it.dests) do
            if done(state, it, d) then have = have or d else todo[#todo + 1] = d end
        end
        if (state.removed or {})[it.key] and not it.queued then
            -- removed just now to make room: leave it
        elseif #todo == 0 then
            res.skipped = res.skipped + 1
            finished_keys[it.key] = true
            if it.queued then downloaded_queue[it.key] = true end
        else
            if progress(string.format("%d/%d  %s", i, #items, it.name), i, #items) == false then
                res.cancelled = true
                break
            end
            -- storage guard: stop before the device fills up (the rest waits for the next sync)
            local free = cfg.free_space and cfg.free_space(cfg.base)
            if free and free - (it.size or 0) < (cfg.min_free or 0) then
                res.storage_full = true
                res.error = string.format("storage nearly full (%.0f MB free, keeping %.0f MB)",
                    free / 1048576, (cfg.min_free or 0) / 1048576)
                break
            end
            -- storage budget: make room by removing the oldest finished books (undo list)
            if cfg.budget and cfg.budget > 0 then
                local okb, fits, names = pcall(extras.make_room, cfg, cat, state, it.size, it.key)
                if okb then
                    for _, n in ipairs(names or {}) do res.auto_removed[#res.auto_removed + 1] = n end
                    if not fits then
                        res.storage_full, res.budget_full = true, true
                        res.error = string.format("the Library storage budget (%s) is full and no more finished books can be removed",
                            util.mb(cfg.budget))
                        break
                    end
                end
            end
            local ok, e
            local source = have
            for _attempt = 1, 2 do
                local first = todo[1]
                if not source then
                    util.mkdirs(first:match("^(.*)/[^/]*$"))
                    ok, e = download(cfg, it, first, function(n)
                        return progress(string.format("%d/%d  %s  %.1f MB", i, #items, it.name, n / 1048576), i, #items)
                    end)
                    if ok then source = first table.remove(todo, 1) break end
                    if e == "cancelled" then break end
                else
                    ok = true break
                end
            end
            if e == "cancelled" then res.cancelled = true break end
            if source then
                for _, d in ipairs(todo) do
                    util.mkdirs(d:match("^(.*)/[^/]*$"))
                    if not util.copy_file(source, d) then ok = nil e = "cannot copy to " .. d end
                end
                local rec = state.files[it.key] or {}
                for _, d in ipairs(it.dests) do
                    local sz = util.file_size(d)
                    if sz then rec[d] = sz end
                end
                state.files[it.key] = rec
                changed[it.key] = true
            end
            if ok then
                res.downloaded = res.downloaded + 1
                res.added[#res.added + 1] = it.name
                finished_keys[it.key] = true
                if it.queued then downloaded_queue[it.key] = true end
            else
                res.failed[#res.failed + 1] = { name = it.name, error = tostring(e) }
                failed_now[it.key] = { name = it.name, error = tostring(e) }
            end
            save()
        end
    end
    if res.cancelled and track then
        -- stopped on purpose: do not pick it up again by itself on the next Wi-Fi connection
        update_state(cfg, function(st) st.pending = {} end)
    end
    if next(downloaded_queue) and cfg.queue_path then
        local q = util.load_table(cfg.queue_path) or {}
        for k in pairs(downloaded_queue) do q[k] = nil end
        util.save_table(cfg.queue_path, q)
    end
    -- removals the user ticked in the sync preview
    if #removals > 0 and not res.cancelled then
        local paths = {}
        for _, r in ipairs(removals) do paths[#paths + 1] = r.path or r end
        M.cleanup(cfg, paths)
        for _, r in ipairs(removals) do
            local p = r.path or r
            if not util.file_size(p) then res.removed[#res.removed + 1] = r.name or p:match("([^/]+)$") end
        end
    end
    save(not res.cancelled and not res.storage_full)
    -- statuses set elsewhere, for the books on the device (also the ones just downloaded)
    if cat and not cfg.only and not cfg.use_plan then
        state = util.load_table(cfg.state_path or "") or state
        local oks, ns = pcall(extras.pull_status, cfg, cat, state)
        res.status_pulled = oks and ns or 0
    end
    -- covers and book info of the books on the device (only the ones that changed)
    if cfg.refresh_meta and cat and not cfg.only and not res.cancelled then
        state = util.load_table(cfg.state_path or "") or state
        local okm, paths = pcall(extras.refresh_meta, cfg, cat, state, progress, cfg.meta_force)
        res.meta_paths = okm and paths or nil
        if not okm then res.meta_error = tostring(paths) end
    end
    return finish()
end

return M
