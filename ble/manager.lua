local defs = require("ble.defs")
local ffi = require("ffi")
local logger = require("logger")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
-- nixio dependency removed, using ffi/libc

local BLEManager = {
    session = nil,
    pipe_r_fd = nil,
    pipe_w_fd = nil,
    poll_task = nil,
    connected = false,
    input_handler_func = nil, -- Function to inject input into main.lua
}

-- Helpers
local function log(msg)
    logger.info("BLE Manager: " .. tostring(msg))
end

local function check_status(status, msg)
    if status ~= defs.C.ACEBT_STATUS_SUCCESS then
        logger.warn("BLE Manager: Error " .. msg .. " (Status: " .. tostring(status) .. ")")
        return false
    end
    return true
end

-- Event Types from adapter.c
local EVENT_NOTIFY = 1
local EVENT_CONNECT = 2
local EVENT_DISCONNECT = 3

-- FFI Constants for Pipe/Fcntl
local O_NONBLOCK = 2048 -- Typical for Linux/ARM (0x800)
local F_GETFL = 3
local F_SETFL = 4

-- Initialize
function BLEManager:init(input_handler)
    self.input_handler_func = input_handler

    if not self.session then
        if not defs.kindlebt then
             logger.warn("BLE Manager: libkindlebt.so not loaded: " .. tostring(defs.err))
             return
        end

        -- Open session
        local handle_ptr = ffi.new("sessionHandle[1]")
        -- Use defs.kindlebt to access KindleBT functions
        local status = defs.kindlebt.aceBT_openSession(defs.C.ACEBT_SESSION_TYPE_GATT_CLIENT, handle_ptr)

        if check_status(status, "Open Session") then
            self.session = handle_ptr[0]
            log("Session Opened: " .. tostring(self.session))

            -- Setup Pipe
            self:setupPipe()

            -- Register callbacks via adapter
            self:registerCallbacks()

            -- Start Polling
            self:startPolling()
        else
             log("Failed to open session. BLE unavailable.")
        end
    end
end

function BLEManager:setupPipe()
    -- Create Pipe using FFI
    local fds = ffi.new("int[2]")
    local ret = defs.C.pipe(fds)

    if ret == 0 then
        local r, w = fds[0], fds[1]

        -- Set Non-blocking (O_NONBLOCK) on read end
        local flags = defs.C.fcntl(r, F_GETFL, 0)
        if flags == -1 then flags = 0 end
        defs.C.fcntl(r, F_SETFL, bit.bor(flags, O_NONBLOCK))

        self.pipe_r_fd = r
        self.pipe_w_fd = w

        -- Pass write FD to adapter (adapter needs simple int)
        defs.adapter.adapter_set_pipe(w)
        log("Pipe created (FFI). Write FD passed to adapter: " .. w)
    else
        log("Failed to create pipe (errno: " .. ffi.errno() .. ")")
    end
end

function BLEManager:registerCallbacks()
    if not self.session then return end

    local cb_struct = ffi.new("bleGattClientCallbacks_t")
    cb_struct.size = ffi.sizeof("bleGattClientCallbacks_t")

    -- Fill with adapter wrappers via adapter lib
    defs.adapter.adapter_get_callbacks(cb_struct)

    local status = defs.kindlebt.aceBT_bleRegisterGattClient(self.session, cb_struct)
    check_status(status, "Register GATT Client")
end

-- Polling Loop
function BLEManager:startPolling()
    if self.poll_task then return end

    self.poll_task = UIManager:scheduleIn(0.05, function()
        self:poll()
        return true -- Reschedule
    end)
end

function BLEManager:poll()
    if not self.pipe_r_fd then return end

    -- Using FFI read
    -- Read Header [Type:1][Len:2] = 3 bytes

    -- Buffer for header
    local hdr_buf = ffi.new("uint8_t[3]")

    while true do
        local n = defs.C.read(self.pipe_r_fd, hdr_buf, 3)

        if n < 0 then
            -- Check errno EAGAIN (11) -> No data
            local err = ffi.errno()
            if err == 11 then return end -- No data, just return
            log("Pipe read error: " .. err)
            break
        end

        if n == 0 then return end -- EOF inside non-blocking read usually means stream closed, but for pipe usually blocks. Here O_NONBLOCK returns -1/EAGAIN. but 0?

        if n < 3 then
             -- Partial header read? Should handle buffering but adapter writes atomically small packets.
             -- If we get < 3 bytes, it's very weird or race condition. Just drop for now.
             log("Pipe partial header read: " .. tonumber(n))
             break
        end

        local type = hdr_buf[0]
        -- Little endian: [type][len_low][len_high]
        local len_low = hdr_buf[1]
        local len_high = hdr_buf[2]
        local len = len_low + (len_high * 256)

        -- Read Payload
        local payload_buf = ffi.new("uint8_t[?]", len)
        local total_read = 0
        local attempts = 0

        -- Loop to read full payload (blocking-ish logic but manual)
        while total_read < len and attempts < 10 do
             local n_pay = defs.C.read(self.pipe_r_fd, payload_buf + total_read, len - total_read)
             if n_pay > 0 then
                 total_read = total_read + n_pay
             elseif n_pay == -1 and ffi.errno() == 11 then
                 -- Wait a tiny bit? Or just break (bad sync)
                 break
             else
                 break
             end
             attempts = attempts + 1
        end

        if total_read < len then
             log("Pipe desync! Expected " .. len .. " got " .. total_read)
             break
        end

        -- Convert C buffer to Lua string for handleEvent
        local payload_str = ffi.string(payload_buf, len)
        self:handleEvent(type, payload_str)
    end
end

function BLEManager:handleEvent(type, payload)
    if type == EVENT_NOTIFY then
        -- Payload: [ConnHandle:ptr_size][DataLen:2][Data...]
        local ptr_size = ffi.sizeof("bleConnHandle")
        local msg_len_offset = ptr_size + 1

        local val_len_low = string.byte(payload, msg_len_offset)
        local val_len_high = string.byte(payload, msg_len_offset + 1)

        if not val_len_low or not val_len_high then return end

        local val_len = val_len_low + (val_len_high * 256)

        local data_offset = msg_len_offset + 2
        local data = string.sub(payload, data_offset, data_offset + val_len - 1)

        -- Trigger Input Event
        if self.input_handler_func then
             self.input_handler_func(data)
        end

    elseif type == EVENT_CONNECT then
        log("Connection Event Received")
    end
end

function BLEManager:connect(mac_str)
    if not self.session then self:init(self.input_handler_func) end
    if not self.session then return false end

    log("Connecting to " .. mac_str)

    local addr = defs.utils.str2addr(mac_str)

    -- Params: min, max, latency, timeout.
    local params = ffi.new("bleConnParam_t")
    params.min_interval = 24
    params.max_interval = 40
    params.latency = 0
    params.timeout = 2000
    params.supervision_timeout = 2000

    -- Use aceBt_bleConnect
    local status = defs.kindlebt.aceBt_bleConnect(self.session, addr, params, 0, true, 0)

    if check_status(status, "Connect") then
        self.connected = true
        return true
    end
    return false
end

-- Cleanup on exit?
-- Need close(fds[0]), close(fds[1])...

return BLEManager
