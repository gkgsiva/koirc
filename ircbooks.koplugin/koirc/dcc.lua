--[[--
DCC SEND receiver: connects to the sender and writes the file to disk.
]]

local Conn = require("koirc/conn")

local Dcc = {}
Dcc.__index = Dcc

local function ack(n)
    n = n % 4294967296
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
                       math.floor(n / 256) % 256, n % 256)
end

--- opts: socket, now, offer (from proto.parseDccSend), path, stall_timeout,
-- offset (bytes already in path .. ".part": continue after them, after the
-- sender accepted a DCC RESUME), keep_partial (keep the .part file of an
-- interrupted transfer so it can be resumed later)
function Dcc.new(opts)
    local self = setmetatable({}, Dcc)
    self.offer = opts.offer
    self.path = opts.path
    self.part = opts.path .. ".part"
    self.now = opts.now
    self.stall_timeout = opts.stall_timeout or 90
    self.offset = tonumber(opts.offset) or 0
    self.keep_partial = opts.keep_partial
    self.received = self.offset
    -- Called with each chunk as it arrives (e.g. to count search results).
    self.on_data = opts.on_data
    self.size = self.offer.size or 0
    self.conn = Conn.new{
        socket = opts.socket, host = self.offer.host, port = self.offer.port,
        now = opts.now, timeout = 30,
    }
    self.state = "running"
    return self
end

function Dcc:fail(err)
    self:abort(self.keep_partial)
    self.state = "error"
    self.err = err
    return self.state, err
end

--- Returns "running", "done" or "error" (plus message).
function Dcc:poll()
    if self.state ~= "running" then return self.state, self.err end
    local cstate, cerr = self.conn:poll()
    if cstate == "error" then return self:fail(cerr) end
    if cstate ~= "open" and cstate ~= "closed" then return self.state end
    if not self.file then
        local f, ferr = io.open(self.part, self.offset > 0 and "ab" or "wb")
        if not f then return self:fail("cannot write file: " .. tostring(ferr)) end
        self.file = f
        self.last_data = self.now()
    end
    local data = self.conn:read(512 * 1024)
    if #data > 0 then
        local ok, werr = self.file:write(data)
        if not ok then return self:fail("write error: " .. tostring(werr)) end
        self.received = self.received + #data
        if self.on_data then pcall(self.on_data, data) end
        self.last_data = self.now()
        if self.conn.state == "open" then self.conn:send(ack(self.received)) end
    end
    local complete = self.size > 0 and self.received >= self.size
    if complete or self.conn.state == "closed" then
        self.conn:close()
        self.file:close()
        self.file = nil
        if self.size > 0 and self.received < self.size then
            if not (self.keep_partial and self.received > 0) then os.remove(self.part) end
            self.state = "error"
            self.err = string.format("transfer interrupted (%d of %d bytes)", self.received, self.size)
            return self.state, self.err
        end
        os.remove(self.path)
        local ok, rerr = os.rename(self.part, self.path)
        if not ok then return self:fail("cannot rename file: " .. tostring(rerr)) end
        self.state = "done"
        return self.state
    end
    if self.now() - self.last_data > self.stall_timeout then
        return self:fail("transfer stalled")
    end
    return self.state
end

--- Stop. keep: leave the partial file for a later resume.
function Dcc:abort(keep)
    self.conn:close()
    if self.file then
        self.file:close()
        self.file = nil
        if not (keep and self.received > 0) then os.remove(self.part) end
    end
end

--- Bytes already saved in path .. ".part", or 0.
function Dcc.partialSize(path)
    local f = io.open(path .. ".part", "rb")
    if not f then return 0 end
    local n = f:seek("end") or 0
    f:close()
    return n
end

return Dcc
