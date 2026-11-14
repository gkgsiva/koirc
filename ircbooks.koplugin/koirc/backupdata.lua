--[[--
What goes into a settings backup and how it is merged back. No KOReader
dependencies (tested in spec/run.lua).
]]

local M = {}

M.PREFIX = "ircbooks-backup"
M.FORMAT = 1

-- Never written to a backup, never overwritten by a restore.
M.SECRETS = { hardcover_token = true, password = true }

local function deepCopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return nil end
    seen[v] = true
    local t = {}
    for k, x in pairs(v) do
        if type(x) ~= "function" and type(x) ~= "userdata" then t[k] = deepCopy(x, seen) end
    end
    seen[v] = nil
    return t
end

--- Settings without secrets. A string anywhere that holds the API key is
-- dropped too, in case it was copied somewhere else.
function M.cleanSettings(settings)
    local token = settings and settings.hardcover_token
    local out = {}
    for k, v in pairs(settings or {}) do
        if not M.SECRETS[k] then out[k] = deepCopy(v) end
    end
    if type(token) == "string" and #token > 8 then
        local function scrub(t)
            for k, v in pairs(t) do
                if type(v) == "string" and v:find(token, 1, true) then t[k] = nil
                elseif type(v) == "table" then scrub(v) end
            end
        end
        scrub(out)
    end
    return out
end

--- opts: settings, library, collections, history, version, now
function M.build(opts)
    return {
        ircbooks_backup = M.FORMAT,
        plugin_version = opts.version,
        created = opts.now,
        settings = M.cleanSettings(opts.settings),
        library = deepCopy(opts.library or {}),
        collections = deepCopy(opts.collections or {}),
        history = deepCopy(opts.history or {}),
    }
end

function M.isBackup(data)
    return type(data) == "table" and tonumber(data.ircbooks_backup) ~= nil and type(data.settings) == "table"
end

--- Take every setting from the backup, keeping the secrets on the device
-- (settings the backup doesn't have stay as they are).
function M.mergeSettings(current, saved)
    if type(saved) ~= "table" then return current end
    local keep = {}
    for k in pairs(M.SECRETS) do keep[k] = current[k] end
    for k, v in pairs(saved) do
        if not M.SECRETS[k] then current[k] = deepCopy(v) end
    end
    for k, v in pairs(keep) do current[k] = v end
    return current
end

return M
