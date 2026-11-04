--[[--
Non-blocking TCP connection (optionally TLS) on top of LuaSocket/LuaSec.
Everything is driven by calling :poll() repeatedly, so the KOReader UI never
blocks waiting on the network (only the DNS lookup is synchronous).
]]

local Conn = {}
Conn.__index = Conn

local function isWouldBlock(err)
    return err == "timeout" or err == "wantread" or err == "wantwrite"
end

--- opts: socket (LuaSocket module), ssl (LuaSec module, optional), host, port,
-- tls (bool), now (function returning seconds), timeout (seconds)
function Conn.new(opts)
    local self = setmetatable({}, Conn)
    self.socket = opts.socket
    self.ssl = opts.ssl
    self.host = opts.host
    self.port = opts.port
    self.tls = opts.tls
    self.now = opts.now or opts.socket.gettime
    self.timeout = opts.timeout or 30
    self.state = "new"
    self.outbuf = ""
    return self
end

function Conn:fail(err)
    self:close()
    self.state = "error"
    self.err = err
    return self.state, err
end

--- Advance the connection. Returns state ("connecting", "handshake",
-- "open", "error", "closed") and an error message for "error".
function Conn:poll()
    if self.state == "new" then
        self.deadline = self.now() + self.timeout
        local sock, err = self.socket.tcp()
        if not sock then return self:fail(err) end
        self.sock = sock
        sock:settimeout(0)
        local ok, cerr = sock:connect(self.host, self.port)
        if ok then
            self.state = "connected"
        elseif isWouldBlock(cerr) or cerr == "Operation already in progress" then
            self.state = "connecting"
        else
            return self:fail(cerr)
        end
    end
    if self.state == "connecting" then
        local _, writable = self.socket.select(nil, { self.sock }, 0)
        if writable and #writable > 0 then
            if self.sock:getpeername() then
                self.state = "connected"
            else
                -- Ask connect again to learn why it failed.
                local ok, err = self.sock:connect(self.host, self.port)
                if ok or err == "already connected" then
                    self.state = "connected"
                else
                    return self:fail(err or "connection refused")
                end
            end
        elseif self.now() > self.deadline then
            return self:fail("connection timed out")
        end
    end
    if self.state == "connected" then
        if self.tls then
            if not self.ssl then return self:fail("TLS is not available") end
            local wrapped, err = self.ssl.wrap(self.sock, {
                mode = "client", protocol = "any", verify = "none",
                options = { "all", "no_sslv2", "no_sslv3" },
            })
            if not wrapped then return self:fail(err) end
            self.sock = wrapped
            self.sock:settimeout(0)
            if self.sock.sni then pcall(self.sock.sni, self.sock, self.host) end
            self.state = "handshake"
        else
            self.state = "open"
        end
    end
    if self.state == "handshake" then
        local ok, err = self.sock:dohandshake()
        if ok then
            self.state = "open"
        elseif not isWouldBlock(err) then
            return self:fail("TLS handshake failed: " .. tostring(err))
        elseif self.now() > self.deadline then
            return self:fail("TLS handshake timed out")
        end
    end
    if self.state == "open" then
        self:flush()
    end
    return self.state, self.err
end

function Conn:send(data)
    self.outbuf = self.outbuf .. data
    if self.state == "open" then self:flush() end
end

function Conn:flush()
    if self.outbuf == "" or not self.sock then return end
    local last, err, partial = self.sock:send(self.outbuf)
    local sent = last or partial or 0
    if sent > 0 then self.outbuf = self.outbuf:sub(sent + 1) end
    if not last and err and not isWouldBlock(err) then
        self:fail(err)
    end
end

--- Read whatever is available. Returns a string (possibly empty).
-- When the peer closed the connection, state becomes "closed".
function Conn:read(max)
    if self.state ~= "open" then return "" end
    local chunks = {}
    local total = 0
    max = max or 1048576
    while total < max do
        local data, err, partial = self.sock:receive(8192)
        data = data or partial
        if data and #data > 0 then
            chunks[#chunks + 1] = data
            total = total + #data
        end
        if err then
            if not isWouldBlock(err) then
                self:close()
                self.state = "closed"
                self.err = err
            end
            break
        end
    end
    return table.concat(chunks)
end

function Conn:close()
    if self.sock then
        pcall(self.sock.close, self.sock)
        self.sock = nil
    end
    if self.state ~= "error" then self.state = "closed" end
end

return Conn
