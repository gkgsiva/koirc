-- Incremental OPDS sync: walks the server's folders and downloads every book
-- into <base>/<folder name>/<file name>.
local ltn12 = require("ltn12")
local xml = require("librarysync/xml")
local util = require("librarysync/util")
local httpmod = require("librarysync/http")

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
                ext = (link.href:gsub("[?#].*$", ""):match("%.(%w+)$") or ""):lower(),
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
        for _, book in ipairs(feed.entries) do
            for _, file in ipairs(M.book_files(cfg, page, book)) do
                folder.files[#folder.files + 1] = file
            end
        end
        local nxt = xml.link(feed, "next")
        page = nxt and util.resolve(page, nxt.href) or nil
    end
    return folder
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
            local folder, rerr = read_folder(cfg, { name = e.title, files = {}, url = util.resolve(folders_url, l.href) }, progress)
            if not folder then return nil, rerr end
            out[#out + 1] = folder
        end
    end
    return out
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
                it = { key = file.key, url = file.url, size = file.size, name = file.name, dests = {} }
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
function M.download_one(cfg, dir, file, progress)
    cfg.transport = cfg.transport or httpmod.get
    cfg.headers = cfg.headers or httpmod.auth_headers(cfg)
    local dest = M.dest(cfg, dir, file)
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

--- Run a sync.
-- cfg: server, auth/username/password/token, base, transport (optional), state_path,
--      progress(text, done, total) -> false to stop.
-- Returns { downloaded, skipped, failed = { {name=, error=} }, total, cancelled, error }.
function M.run(cfg)
    cfg.transport = cfg.transport or httpmod.get
    cfg.headers = cfg.headers or httpmod.auth_headers(cfg)
    local progress = cfg.progress or function() end
    local res = { downloaded = 0, skipped = 0, failed = {}, total = 0 }
    local state = (cfg.state_path and util.load_table(cfg.state_path)) or {}
    state.files = state.files or {}

    local folders, err = M.crawl(cfg, progress)
    if not folders then
        res.error = err
        res.cancelled = err == "cancelled"
        return res
    end
    local items = M.plan(folders, cfg.base)
    res.total = #items
    util.mkdirs(cfg.base)

    local changed = {}
    local function save(finished)
        update_state(cfg, function(st)
            for k in pairs(changed) do st.files[k] = state.files[k] end
            if finished then st.last_sync = os.time() end
        end)
        changed = {}
    end

    for i, it in ipairs(items) do
        local todo, have = {}, nil
        for _, d in ipairs(it.dests) do
            if done(state, it, d) then have = have or d else todo[#todo + 1] = d end
        end
        if #todo == 0 then
            res.skipped = res.skipped + 1
        else
            if progress(string.format("%d/%d  %s", i, #items, it.name), i, #items) == false then
                res.cancelled = true
                break
            end
            local ok, e
            local source = have
            for attempt = 1, 2 do
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
                    local s = util.file_size(d)
                    if s then rec[d] = s end
                end
                state.files[it.key] = rec
                changed[it.key] = true
                save()
            end
            if ok then res.downloaded = res.downloaded + 1
            else res.failed[#res.failed + 1] = { name = it.name, error = tostring(e) } end
        end
    end
    save(not res.cancelled)
    return res
end

return M
