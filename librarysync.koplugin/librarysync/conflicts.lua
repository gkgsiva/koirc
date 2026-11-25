-- Reading-progress conflicts: this device has an unsent place for a book while another device
-- moved the Library's place too, and the two differ. The sync then sends neither; the user
-- picks one (Library ▸ Progress conflicts, or when the book opens).
-- Files: cfg.conflicts_path = { [key] = { name=, ["local"] = {percent=, at=}, remote = {percent=, at=}, found_at= } }
-- No KOReader dependencies.
local util = require("librarysync/util")

local M = {}

M.MIN_DIFF = 0.01   -- places closer than 1 % are the same place
M.SLACK = 30        -- seconds of clock difference forgiven

--- Is the Library's place r a conflict with the place p waiting on this device?
-- known: { sent_at=, sent_pct= (what this device sent last), seen_at= (the Library place an
-- earlier sync brought to this device: it was offered when the book opened) }.
-- So: a conflict when the Library's place moved since this device last sent or fetched it.
function M.is_conflict(p, r, known)
    if not (type(p) == "table" and p.percent and type(r) == "table" and r.percent and r.at) then return false end
    if p.force then return false end                                     -- the user chose this device's place
    if math.abs(r.percent - p.percent) < M.MIN_DIFF then return false end -- same place anyway
    known = known or {}
    -- the Library still holds what this device sent (its time may differ: the server dates
    -- places older than a week "now")
    if known.sent_pct and math.abs(r.percent - known.sent_pct) < M.MIN_DIFF then return false end
    local base = math.max(known.sent_at or 0, known.seen_at or 0)
    return r.at > base + M.SLACK
end

function M.load(cfg) return cfg.conflicts_path and util.load_table(cfg.conflicts_path) or {} end

function M.count(cfg)
    local n = 0
    for _k in pairs(M.load(cfg)) do n = n + 1 end
    return n
end

--- Sorted list { {key=, name=, local=, remote=} }, newest first.
function M.list(cfg)
    local out = {}
    for key, c in pairs(M.load(cfg)) do
        if type(c) == "table" then
            out[#out + 1] = { key = key, name = c.name or key, ["local"] = c["local"] or {}, remote = c.remote or {},
                              found_at = c.found_at }
        end
    end
    table.sort(out, function(a, b)
        local x, y = a.remote.at or 0, b.remote.at or 0
        if x ~= y then return x > y end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

function M.add(cfg, key, entry)
    if not cfg.conflicts_path then return end
    local all = M.load(cfg)
    all[key] = entry
    util.save_table(cfg.conflicts_path, all)
end

function M.drop(cfg, key)
    if not cfg.conflicts_path then return end
    local all = M.load(cfg)
    if all[key] then
        all[key] = nil
        util.save_table(cfg.conflicts_path, all)
    end
end

--- Keep this device's place: the next sync sends it (over the Library's).
-- cfg: positions_path (or positions_file), conflicts_path, remote_path.
function M.keep_local(cfg, key)
    local c = M.load(cfg)[key]
    local ppath = cfg.positions_file or cfg.positions_path
    if ppath then
        local pending = util.load_table(ppath) or {}
        local p = pending[key] or (c and c["local"] and { percent = c["local"].percent, at = c["local"].at })
        if p then
            p.force = true
            pending[key] = p
            util.save_table(ppath, pending)
        end
    end
    if cfg.remote_path then
        local remote = util.load_table(cfg.remote_path) or {}
        if remote[key] then remote[key].handled = true util.save_table(cfg.remote_path, remote) end
    end
    M.drop(cfg, key)
end

--- Take the Library's place: this device's waiting place is dropped, and the book goes there
-- the next time it opens (or now, by the caller, when it is open). Returns the percent.
-- update_state(fn): the sync state updater (sent_at / sent_pct are set to the Library's place).
function M.use_remote(cfg, key, update_state)
    local c = M.load(cfg)[key]
    if not c then return nil end
    local ppath = cfg.positions_file or cfg.positions_path
    if ppath then
        local pending = util.load_table(ppath) or {}
        if pending[key] then pending[key] = nil util.save_table(ppath, pending) end
    end
    local r = c.remote or {}
    if update_state then
        update_state(function(st)
            st.sent_at = st.sent_at or {}
            st.sent_pct = st.sent_pct or {}
            st.sent_at[key], st.sent_pct[key] = r.at, r.percent
        end)
    end
    if cfg.remote_path then
        local remote = util.load_table(cfg.remote_path) or {}
        remote[key] = { percent = r.percent, at = r.at, jump = true }
        util.save_table(cfg.remote_path, remote)
    end
    M.drop(cfg, key)
    return r.percent
end

return M
