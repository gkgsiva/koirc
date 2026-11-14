--[[--
IRC ebook fetcher: keeps one IRC connection, runs a search or download job
over it and receives the resulting files by DCC.

The object never blocks. The owner calls :step() periodically; it returns the
number of seconds after which it wants to be called again, or nil when there
is nothing left to do (disconnected and idle).

Job handlers (all optional):
    on_status(text)               human readable progress line
    on_progress(received, total, found)  bytes during a DCC transfer, and
                                  for searches the results counted so far
    on_done(result)               search: array of entries; download: file path
    on_error(message, reason)     reason (downloads): "offline" (the bot is not
                                  in the channel), "no_reply" (the bot never
                                  answered), "refused" (the bot said it can't
                                  send it), "stalled", "transfer", "timeout",
                                  "disconnected" or "error"; used to decide
                                  whether to try another bot.
]]

local Conn = require("koirc/conn")
local Dcc = require("koirc/dcc")
local proto = require("koirc/proto")
local results = require("koirc/results")
local unzip = require("koirc/unzip")

local Fetcher = {}
Fetcher.__index = Fetcher

Fetcher.SEARCH_TIMEOUT = 120
Fetcher.DOWNLOAD_TIMEOUT = 600
Fetcher.REGISTER_TIMEOUT = 90
Fetcher.IDLE_TIMEOUT = 300
Fetcher.JOIN_SETTLE = 3
-- After joining, wait up to this long for the channel's user list, so we
-- know which bots are online before asking one for a book.
Fetcher.NAMES_WAIT = 5
-- Seconds to wait for a bot to accept a DCC RESUME before downloading the
-- whole file again.
Fetcher.RESUME_WAIT = 15

local BOOK_EXTS = {
    epub = true, mobi = true, azw = true, azw3 = true, pdf = true, fb2 = true,
    djvu = true, txt = true, rtf = true, doc = true, docx = true, lit = true,
    cbz = true, cbr = true, htm = true, html = true, pdb = true, prc = true,
}

-- What a book bot says when it won't send the file.
local REFUSED_PATTERNS = {
    "file not found", "no such file", "does not exist", "invalid request",
    "not available", "is not in my list", "couldn't find", "could not find",
}

local NO_RESULTS_PATTERNS = {
    "returned no matches", "no matches", "no results", "nothing found",
    "found 0 ", "0 results",
}

--- opts: socket, ssl (optional), now (optional), config (table or function
-- returning {host, port, tls, nick, channel, search_cmd}), work_dir, log
function Fetcher.new(opts)
    local self = setmetatable({}, Fetcher)
    self.socket = opts.socket
    self.ssl = opts.ssl
    self.now = opts.now or opts.socket.gettime
    self.config = opts.config
    self.work_dir = opts.work_dir
    self.log = opts.log or function() end
    self.buf = ""
    self.last_activity = self.now()
    return self
end

function Fetcher:getConfig()
    if type(self.config) == "function" then return self.config() end
    return self.config
end

local function stripFormatting(s)
    s = s:gsub("\3%d%d?,%d%d?", ""):gsub("\3%d%d?", "")
    return (s:gsub("[\2\3\15\22\29\31]", ""))
end

function Fetcher:status(text)
    local job = self.job
    if job and job.handlers.on_status then job.handlers.on_status(text) end
end

function Fetcher:sendRaw(line)
    self.log("> " .. line)
    if self.conn then self.conn:send(line:sub(1, 510) .. "\r\n") end
end

function Fetcher:isConnected()
    return self.irc_state == "ready"
end

function Fetcher:isBusy()
    return self.job ~= nil
end

function Fetcher:connect()
    if self.conn then return end
    local cfg = self:getConfig()
    self.channel = cfg.channel
    self.base_nick = cfg.nick
    self.nick = cfg.nick
    self.buf = ""
    self.nick_tries = 0
    self.conn = Conn.new{
        socket = self.socket, ssl = self.ssl, host = cfg.host,
        port = tonumber(cfg.port), tls = cfg.tls, now = self.now, timeout = 30,
    }
    self.irc_state = "connecting"
    self.state_deadline = self.now() + Fetcher.REGISTER_TIMEOUT
    self:status(string.format("Connecting to %s:%s…", cfg.host, tostring(cfg.port)))
end

function Fetcher:disconnect(reason)
    if self.conn then
        if self.conn.state == "open" then
            self:sendRaw("QUIT :" .. (reason or "bye"))
            self.conn:flush()
        end
        self.conn:close()
    end
    self.conn = nil
    self.irc_state = nil
    self.names = nil
end

function Fetcher:onDisconnected(err)
    self.log("disconnected: " .. tostring(err))
    self.last_error = tostring(err)
    if self.conn then self.conn:close() end
    self.conn = nil
    self.irc_state = nil
    self.names = nil
    if self.job and not self.job.dcc then
        self:failJob("Disconnected from IRC: " .. tostring(err), "disconnected")
    end
end

function Fetcher:startJob(job)
    if self.job then return false, "busy" end
    job.handlers = job.handlers or {}
    self.job = job
    self.last_activity = self.now()
    if not self.conn then
        self:connect()
    elseif self.irc_state == "ready" then
        self:status("Connected.")
    end
    return true
end

--- Start a search. Returns true, or false + error when another job runs.
function Fetcher:search(query, handlers)
    return self:startJob{ kind = "search", query = query, handlers = handlers }
end

--- Request a result entry (from results.parse) and save it into dir.
-- opts.ack_timeout: give up (reason "no_reply") when the bot has said
-- nothing and sent nothing after this many seconds, so another bot can be
-- tried instead of waiting the full DOWNLOAD_TIMEOUT.
function Fetcher:download(entry, dir, handlers, opts)
    return self:startJob{ kind = "download", entry = entry, dir = dir, handlers = handlers, opts = opts or {} }
end

--- Is nick in the channel? true/false, or nil when we don't know (the
-- server has not sent the channel's user list).
function Fetcher:botOnline(nick)
    if not self.names or not nick then return nil end
    return self.names[nick:lower()] == true
end

--- Stop the current job. keep_partial: leave a half-downloaded book so it
-- can be continued later (the device sleeps, Wi-Fi goes off).
function Fetcher:cancel(keep_partial)
    local job = self.job
    if not job then return end
    local keep = keep_partial and job.kind == "download"
    if job.dcc then job.dcc:abort(keep) end
    if not keep and job.dcc_path then os.remove(job.dcc_path .. ".part.info") end
    self.job = nil
    return keep and job.dcc ~= nil and job.dcc.received > 0
end

--- Is there a half-downloaded book for this job? Bytes saved, or nil.
function Fetcher:partialOf(job)
    return job and job.partial
end

function Fetcher:finishJob(result)
    local job = self.job
    self.job = nil
    self.last_activity = self.now()
    if self.on_download_stats and job and job.kind == "download" then
        local now = self.now()
        pcall(self.on_download_stats, {
            bot = job.entry.bot, ok = true,
            bytes = job.bytes, secs = job.dcc_started and (now - job.dcc_started) or nil,
            wait = job.sent_at and job.dcc_started and (job.dcc_started - job.sent_at) or nil,
        })
    end
    if job and job.handlers.on_done then job.handlers.on_done(result) end
end

function Fetcher:failJob(err, reason)
    self.last_error = err
    local job = self.job
    if not job then return end
    if job.dcc then job.dcc:abort(job.kind == "download") end
    self.job = nil
    self.last_activity = self.now()
    if self.on_download_stats and job.kind == "download" then
        pcall(self.on_download_stats, { bot = job.entry.bot, ok = false, reason = reason or "error" })
    end
    if job.handlers.on_error then job.handlers.on_error(err, reason or "error") end
end

function Fetcher:sendJobCommand()
    local job = self.job
    local cfg = self:getConfig()
    if job.kind == "search" then
        local cmd = cfg.search_cmd
        if not cmd or cmd == "" then cmd = "@search" end
        self:sendRaw(string.format("PRIVMSG %s :%s %s", self.channel, cmd, job.query))
        job.deadline = self.now() + Fetcher.SEARCH_TIMEOUT
        self:status(string.format("Searching for “%s”…", job.query))
    else
        if self:botOnline(job.entry.bot) == false then
            return self:failJob(job.entry.bot .. " is offline (not in " .. self.channel .. ").", "offline")
        end
        self:sendRaw(string.format("PRIVMSG %s :%s", self.channel, job.entry.request))
        job.deadline = self.now() + Fetcher.DOWNLOAD_TIMEOUT
        local ack = job.opts and tonumber(job.opts.ack_timeout)
        if ack then job.ack_deadline = self.now() + ack end
        self:status(string.format("Requesting book from %s…", job.entry.bot))
    end
    job.sent = true
    job.sent_at = self.now()
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function uniquePath(dir, name)
    local path = dir .. "/" .. name
    if not fileExists(path) then return path end
    local stem, ext = name:match("^(.*)(%.[^%.]+)$")
    if not stem then stem, ext = name, "" end
    for i = 1, 999 do
        path = string.format("%s/%s (%d)%s", dir, stem, i, ext)
        if not fileExists(path) then return path end
    end
    return path
end

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(data)
    f:close()
    if not ok then os.remove(path) return nil, werr end
    return true
end

function Fetcher:handleDcc(nick, args)
    local job = self.job
    if not job or not job.sent or job.dcc or job.resume then
        self.log("ignoring unexpected DCC from " .. tostring(nick))
        return
    end
    local offer, err = proto.parseDccSend(args)
    if not offer then
        self.log("bad DCC offer: " .. tostring(err))
        return
    end
    local name = proto.safeFilename(offer.filename)
    if job.kind == "download" then
        local wanted = job.entry.bot:lower()
        local title = proto.safeFilename(job.entry.title):lower()
        if nick:lower() ~= wanted and name:lower() ~= title then
            self.log("ignoring DCC from " .. nick .. " (waiting for " .. job.entry.bot .. ")")
            return
        end
    end
    if offer.passive then
        return self:failJob(nick .. " offered a passive (reverse) DCC transfer, which is not supported.")
    end
    if not offer.host then
        return self:failJob("Invalid DCC address from " .. nick .. ": " .. tostring(offer.addr))
    end
    local path
    if job.kind == "search" then
        path = self.work_dir .. "/" .. name
    else
        path = uniquePath(job.dir, name)
        -- A half-downloaded copy of this file: ask the bot to continue it.
        local have = Dcc.partialSize(path)
        local size = tonumber(readFile(path .. ".part.info") or "")
        if have > 0 and offer.size and have < offer.size and size == offer.size then
            job.resume = { offer = offer, path = path, name = name, pos = have, nick = nick,
                           deadline = self.now() + Fetcher.RESUME_WAIT }
            local fname = offer.filename:find(" ", 1, true) and ('"' .. offer.filename .. '"') or offer.filename
            self:sendRaw(string.format("PRIVMSG %s :\1DCC RESUME %s %d %d\1", nick, fname, offer.port, have))
            self:status(string.format("Continuing %s at %d%%…", name, math.floor(have * 100 / offer.size)))
            return
        end
        writeFile(path .. ".part.info", tostring(offer.size or ""))
    end
    self:startDcc(offer, path, name, 0)
end

--- Connect to the sender and receive the file, from offset bytes on.
function Fetcher:startDcc(offer, path, name, offset)
    local job = self.job
    job.resume = nil
    local on_data
    if job.kind == "search" then
        local counter = results.newCounter()
        on_data = function(data) job.found = counter(data) end
    end
    job.dcc = Dcc.new{ socket = self.socket, now = self.now, offer = offer, path = path, on_data = on_data,
                       offset = offset, keep_partial = job.kind == "download" }
    job.dcc_path = path
    job.dcc_name = name
    job.dcc_started = self.now()
    job.resumed_from = offset > 0 and offset or nil
    if job.kind == "search" then
        self:status("Receiving search results…")
    elseif offset > 0 then
        self:status("Continuing " .. name .. "…")
    else
        self:status("Downloading " .. name .. "…")
    end
end

--- The bot agreed to continue a half-downloaded file ("DCC ACCEPT").
function Fetcher:handleDccAccept(nick, args)
    local job = self.job
    local r = job and job.resume
    if not r then return end
    local port, pos = tostring(args):match("(%d+)%s+(%d+)%s*$")
    if tonumber(port) ~= r.offer.port then return end
    pos = tonumber(pos)
    if not pos or pos <= 0 or pos > r.pos then pos = 0 end
    self.log(string.format("%s accepted resume at %d", nick, pos))
    if pos == 0 then
        os.remove(r.path .. ".part")
    elseif pos < r.pos then
        -- Keep only what the sender will continue after.
        local data = readFile(r.path .. ".part")
        if data then writeFile(r.path .. ".part", data:sub(1, pos)) end
    end
    self:startDcc(r.offer, r.path, r.name, pos)
end

function Fetcher:completeSearch(path)
    local data, err = readFile(path)
    os.remove(path)
    if not data then return self:failJob("Cannot read results: " .. tostring(err)) end
    local text = data
    if unzip.isZip(data) then
        local files, zerr = unzip.extractAll(data)
        if not files or #files == 0 then
            return self:failJob("Cannot unpack results: " .. tostring(zerr or "empty archive"))
        end
        text = nil
        for _, f in ipairs(files) do
            if f.name:lower():match("%.txt$") then text = f.data break end
        end
        text = text or files[1].data
    end
    self:finishJob(results.parse(text))
end

function Fetcher:completeDownload(path)
    os.remove(path .. ".part.info")
    if self.job then self.job.bytes = self.job.dcc_size end
    -- Unpack a zip that only wraps a single book.
    if path:lower():match("%.zip$") then
        local data = readFile(path)
        if data and unzip.isZip(data) then
            local entries = unzip.list(data)
            local files = {}
            for _, e in ipairs(entries or {}) do
                if e.name:sub(-1) ~= "/" then files[#files + 1] = e end
            end
            if #files == 1 then
                local ext = files[1].name:match("%.(%w+)$")
                if ext and BOOK_EXTS[ext:lower()] then
                    local content = unzip.extract(data, files[1])
                    if content then
                        local dir = path:match("^(.*)/[^/]*$") or "."
                        local target = uniquePath(dir, proto.safeFilename(files[1].name))
                        if writeFile(target, content) then
                            os.remove(path)
                            path = target
                        end
                    end
                end
            end
        end
    end
    self:finishJob(path)
end

function Fetcher:handleMessage(msg)
    local job = self.job
    local text = msg.params[2] or ""
    local target = msg.params[1] or ""
    local to_me = self.nick and target:lower() == self.nick:lower()
    if not to_me or not msg.nick or not (msg.prefix or ""):find("!", 1, true) then
        return -- channel chatter or server notices
    end
    local ctcp, args = proto.parseCtcp(text)
    if ctcp then
        if msg.command == "PRIVMSG" then
            if ctcp == "VERSION" then
                self:sendRaw(string.format("NOTICE %s :\1VERSION KOReader IRC book search\1", msg.nick))
            elseif ctcp == "PING" then
                self:sendRaw(string.format("NOTICE %s :\1PING %s\1", msg.nick, args))
            elseif ctcp == "DCC" then
                if tostring(args):match("^%s*ACCEPT") then
                    self:handleDccAccept(msg.nick, args)
                else
                    self:handleDcc(msg.nick, args)
                end
            end
        end
        return
    end
    if not job or not job.sent then return end
    text = stripFormatting(text)
    self:status(msg.nick .. ": " .. text)
    local lower = text:lower()
    if job.kind == "search" and not job.dcc then
        for _, pat in ipairs(NO_RESULTS_PATTERNS) do
            if lower:find(pat, 1, true) then
                return self:finishJob({})
            end
        end
    elseif job.kind == "download" and msg.nick:lower() == job.entry.bot:lower() then
        if not job.dcc then
            for _, pat in ipairs(REFUSED_PATTERNS) do
                if lower:find(pat, 1, true) then
                    return self:failJob(msg.nick .. ": " .. text, "refused")
                end
            end
        end
        -- The bot is talking to us (queue position etc.), keep waiting.
        job.acked = true
        job.deadline = math.max(job.deadline or 0, self.now() + Fetcher.DOWNLOAD_TIMEOUT)
    end
end

--- Someone left the channel; when it is the bot we wait for, stop waiting.
function Fetcher:userLeft(nick)
    if self.names then self.names[nick:lower()] = nil end
    local job = self.job
    if job and job.kind == "download" and job.sent and not job.dcc and nick:lower() == job.entry.bot:lower() then
        self:failJob(nick .. " went offline.", "offline")
    end
end

function Fetcher:handleLine(line)
    self.log("< " .. line)
    local msg = proto.parseLine(line)
    if not msg then return end
    local cmd = msg.command
    if cmd == "PING" then
        self:sendRaw("PONG :" .. (msg.params[1] or ""))
    elseif cmd == "001" then
        self.nick = msg.params[1] or self.nick
        self.irc_state = "joining"
        self:status("Joining " .. self.channel .. "…")
        self:sendRaw("JOIN " .. self.channel)
    elseif (cmd == "433" or cmd == "432" or cmd == "436") and self.irc_state == "registering" then
        self.nick_tries = self.nick_tries + 1
        if self.nick_tries > 5 then
            self:failJob("Nickname " .. self.base_nick .. " is not available.")
            return self:disconnect()
        end
        local base = cmd == "432" and "koreader" or self.base_nick
        self.nick = base:sub(1, 12) .. tostring(math.random(100, 999))
        self:sendRaw("NICK " .. self.nick)
    elseif cmd == "353" then
        -- Channel user list after joining: "353 me = #chan :@op +voice nick"
        if (msg.params[3] or ""):lower() == (self.channel or ""):lower() then
            self.names_new = self.names_new or {}
            for n in (msg.params[4] or ""):gmatch("%S+") do
                self.names_new[n:gsub("^[~&@%%+]+", ""):lower()] = true
            end
        end
    elseif cmd == "366" then
        if self.names_new then self.names = self.names_new end
        self.names_new = nil
        self.names_done = true
    elseif cmd == "NICK" and msg.nick and self.nick and msg.nick:lower() == self.nick:lower() then
        self.nick = msg.params[1]
    elseif cmd == "NICK" and msg.nick then
        if self.names and self.names[msg.nick:lower()] then
            self.names[msg.nick:lower()] = nil
            self.names[(msg.params[1] or ""):lower()] = true
        end
    elseif (cmd == "PART" or cmd == "QUIT") and msg.nick and (cmd == "QUIT" or (msg.params[1] or ""):lower() == (self.channel or ""):lower()) then
        self:userLeft(msg.nick)
    elseif cmd == "JOIN" and msg.nick and self.names and self.nick and msg.nick:lower() ~= self.nick:lower()
        and (msg.params[1] or ""):lower() == (self.channel or ""):lower() then
        self.names[msg.nick:lower()] = true
    elseif cmd == "JOIN" and msg.nick and self.nick and msg.nick:lower() == self.nick:lower() then
        if (msg.params[1] or ""):lower() == self.channel:lower() then
            self.irc_state = "ready"
            self.ready_at = self.now() + Fetcher.JOIN_SETTLE
            self.names_done = false
            self:status("Joined " .. self.channel .. ".")
        end
    elseif cmd == "403" or cmd == "405" or cmd == "471" or cmd == "473"
        or cmd == "474" or cmd == "475" or cmd == "477" or cmd == "489" then
        if self.irc_state == "joining" then
            local reason = msg.params[#msg.params] or cmd
            self:failJob("Cannot join " .. self.channel .. ": " .. reason)
            self:disconnect()
        end
    elseif cmd == "KICK" and self.nick and (msg.params[2] or ""):lower() == self.nick:lower() then
        self:failJob("Kicked from " .. self.channel .. ": " .. (msg.params[3] or ""), "disconnected")
        self:disconnect()
    elseif cmd == "KICK" and msg.params[2] then
        self:userLeft(msg.params[2])
    elseif cmd == "ERROR" then
        self:onDisconnected(msg.params[1] or "server error")
    elseif cmd == "PRIVMSG" or cmd == "NOTICE" then
        self:handleMessage(msg)
    end
end

--- Drive everything. Returns seconds until the next call, or nil when idle.
function Fetcher:step()
    local now = self.now()
    if self.conn then
        local st, err = self.conn:poll()
        if st == "error" or st == "closed" then
            self:onDisconnected(err or "connection closed")
        elseif st == "open" then
            if self.irc_state == "connecting" then
                local cfg = self:getConfig()
                self.irc_state = "registering"
                self:status("Logging in as " .. self.nick .. "…")
                if cfg.password and cfg.password ~= "" then
                    self:sendRaw("PASS " .. cfg.password)
                end
                self:sendRaw("NICK " .. self.nick)
                self:sendRaw("USER " .. self.nick .. " 0 * :KOReader")
            end
            local data = self.conn:read()
            if #data > 0 then
                self.buf = self.buf .. data
                while self.conn do
                    local line, rest = self.buf:match("^([^\n]*)\n(.*)$")
                    if not line then break end
                    self.buf = rest
                    self:handleLine(line)
                end
            end
            if self.conn and self.conn.state == "closed" then
                self:onDisconnected(self.conn.err or "connection closed")
            end
        end
        if self.irc_state and self.irc_state ~= "ready" and now > self.state_deadline then
            self:failJob("Timed out connecting to IRC.")
            self:disconnect()
        end
    end

    local job = self.job
    if job then
        if not job.sent then
            local ready_at = self.ready_at or 0
            if self.irc_state == "ready" and now >= ready_at
                and (self.names_done ~= false or now >= ready_at + Fetcher.NAMES_WAIT) then
                self:sendJobCommand()
            elseif not self.conn then
                self:connect()
            end
        elseif job.resume then
            if now > job.resume.deadline then
                -- The bot does not resume; start over.
                local r = job.resume
                self.log("no answer to DCC RESUME, downloading " .. r.name .. " again")
                os.remove(r.path .. ".part")
                writeFile(r.path .. ".part.info", tostring(r.offer.size or ""))
                self:startDcc(r.offer, r.path, r.name, 0)
            end
        elseif job.dcc then
            local st, err = job.dcc:poll()
            if job.handlers.on_progress then
                job.handlers.on_progress(job.dcc.received, job.dcc.size, job.found)
            end
            if st == "done" then
                job.dcc_size = job.dcc.received - (job.resumed_from or 0)
                job.dcc = nil
                if job.kind == "search" then
                    self:completeSearch(job.dcc_path)
                else
                    self:completeDownload(job.dcc_path)
                end
            elseif st == "error" then
                local kept = job.kind == "download" and job.dcc.received > 0
                    and Dcc.partialSize(job.dcc.path) > 0
                job.dcc = nil
                local reason = tostring(err):find("stalled", 1, true) and "stalled" or "transfer"
                -- Part of the book is saved: the same bot can continue it.
                if kept then job.partial = true reason = "interrupted" end
                self:failJob("Transfer failed: " .. tostring(err), reason)
            end
        elseif job.ack_deadline and not job.acked and now > job.ack_deadline then
            self:failJob(job.entry.bot .. " did not answer. It may be offline.", "no_reply")
        elseif job.deadline and now > job.deadline then
            if job.kind == "search" then
                self:failJob("No answer from the search bot. Try again later or check the search command.", "timeout")
            else
                self:failJob("The bot did not send the book in time. It may be offline or busy.", "timeout")
            end
        end
    elseif self.conn and now - self.last_activity > Fetcher.IDLE_TIMEOUT then
        self:disconnect("idle")
    end

    if self.job and self.job.dcc then return 0.05 end
    if self.job and self.job.resume then return 0.2 end
    if self.job then return 0.2 end
    if self.conn then return 1 end
    return nil
end

return Fetcher
