-- =======================================================
-- 设置 Lua 路径 (适配 KOReader 环境)
-- =======================================================
package.path = "/mnt/us/koreader/common/?.lua;/mnt/us/koreader/lualib/?.lua;/mnt/us/koreader/?.lua;/mnt/us/koreader/frontend/?.lua;/mnt/us/koreader/plugins/?.lua;" .. package.path
-- socket.core通常在 libs/socket/core.so 或 libs/libsocket.so
-- 用户反馈 score.so (可能是 core.so) 在 koreader/common/socket
package.cpath = "/mnt/us/koreader/common/socket/?.so;/mnt/us/koreader/common/?.so;/mnt/us/koreader/libs/?.so;/mnt/us/koreader/libs/lib?.so;/mnt/us/koreader/libs/?/core.so;" .. package.cpath

local ffi = require("ffi")
local socket = require("socket")
local bit = require("bit")

-- =======================================================
-- 获取当前脚本目录 (用于加载 .so)
-- =======================================================
local function get_script_dir()
    local str = debug.getinfo(1, "S").source:sub(2)
    return str:match("(.*/)")
end
local SCRIPT_DIR = get_script_dir() or "./"

-- =======================================================
-- FFI 定义
-- =======================================================
ffi.cdef[[
    // 权限与 IO
    int setuid(int uid);
    int setgid(int gid);
    int getuid(void);
    int getgid(void);
    int pipe(int pipefd[2]);
    int read(int fd, void *buf, size_t count);
    int close(int fd);

    // Poll
    struct pollfd {
        int fd;
        short events;
        short revents;
    };
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    static const int POLLIN = 0x0001;

    // KindleBT Types
    typedef int status_t;
    typedef int sessionType_t;
    typedef void* sessionHandle;
    typedef void* bleConnHandle;

    // KindleBT Functions
    bool isBLESupported(void);
    status_t openSession(int session_type, sessionHandle* session_handle);
    status_t bleRegister(sessionHandle session_handle);
    status_t bleRegisterGattClient(sessionHandle session_handle, void* callbacks);
    status_t closeSession(sessionHandle session_handle);

    // Connect Signature: (session, conn_handle*, bd_addr*, param, role, prio)
    // bd_addr is struct { uint8_t address[6]; }
    typedef struct { uint8_t address[6]; } bdAddr_t;
    status_t bleConnect(sessionHandle session, bleConnHandle* conn_handle, bdAddr_t* p_device, int p1, int p2, int p3);
    status_t bleDisconnect(bleConnHandle conn_handle);

    // Adapter Functions
    void set_notify_pipe(int fd);
    status_t register_gatt_callbacks(sessionHandle session);
]]

-- =======================================================
-- 全局状态
-- =======================================================
local lib_kbt = nil
local lib_adapter = nil
local session = nil
local pipe_fds = ffi.new("int[2]")
local conn_handle = nil
local server_socket = nil
local client_socket = nil

-- =======================================================
-- 辅助函数
-- =======================================================
local function str2addr(addr_str)
    local addr = ffi.new("bdAddr_t")
    local i = 0
    for b in addr_str:gmatch("%x+") do
        if i < 6 then
            addr.address[5-i] = tonumber(b, 16)
            i = i + 1
        end
    end
    return addr
end

local function drop_privileges()
    local uid, gid = 1003, 1003
    local current_gid = ffi.C.getgid()
    local current_uid = ffi.C.getuid()
    print("Current UID: " .. current_uid .. " GID: " .. current_gid)

    if current_gid ~= gid then
        if ffi.C.setgid(gid) ~= 0 then return false, "setgid failed" end
    end
    if current_uid ~= uid then
        if ffi.C.setuid(uid) ~= 0 then return false, "setuid failed" end
    end
    print("Dropped privileges to " .. uid)
    return true
end

local function load_lib(name, paths)
    for _, path in ipairs(paths) do
        local full_path = path
        if path:sub(-1) == "/" then
            full_path = path .. name
        else
            -- If path doesn't end in /, assume it is just a directory, append /name
            -- Or if it is empty string, use name directly (system load)
            if path == "" then full_path = name else full_path = path .. "/" .. name end
        end

        local ok, lib = pcall(ffi.load, full_path, true)
        if ok then
            print("Loaded " .. name .. " from " .. full_path)
            return lib
        end
    end
    return nil, "Failed to load " .. name
end

local function init_bluetooth()
    print("Initializing Bluetooth (Force /mnt/us/koreader/libs)...")

    local lib_path = "/mnt/us/koreader/libs/"
    local kbt_path = lib_path .. "libkindlebt.so"
    local adp_path = lib_path .. "libkindlebt_adapter.so"

    local ok, lib = pcall(ffi.load, kbt_path, true)
    if not ok then return false, "Failed load " .. kbt_path .. ": " .. tostring(lib) end
    lib_kbt = lib

    local ok2, lib2 = pcall(ffi.load, adp_path)
    if not ok2 then return false, "Failed load " .. adp_path .. ": " .. tostring(lib2) end
    lib_adapter = lib2

    if ffi.C.pipe(pipe_fds) ~= 0 then return false, "Pipe failed" end
    lib_adapter.set_notify_pipe(pipe_fds[1])

    local handle_ptr = ffi.new("sessionHandle[1]")
    local status = lib_kbt.openSession(2, handle_ptr)
    if status ~= 0 then return false, "openSession(2) failed: " .. status end
    session = handle_ptr[0]

    if lib_kbt.bleRegister(session) ~= 0 then return false, "bleRegister failed" end
    if lib_adapter.register_gatt_callbacks(session) ~= 0 then return false, "register_gatt_cb failed" end

    print("Bluetooth Initialized.")
    return true
end

local function handle_command(cmd)
    local action, arg = cmd:match("(%w+)%s*(.*)")
    if action == "CONNECT" and arg then
        print("Connecting to " .. arg)
        local addr = str2addr(arg)
        local conn_ptr = ffi.new("sessionHandle[1]")
        -- param=0, role=0, prio=0 (Updated based on testing)
        local ret = lib_kbt.bleConnect(session, conn_ptr, addr, 0, 0, 0)
        if ret == 0 then
            conn_handle = conn_ptr[0]
            print("Connect requested")
        else
            print("Connect failed: " .. ret)
        end
    elseif action == "DISCONNECT" then
        if conn_handle then
            lib_kbt.bleDisconnect(conn_handle)
            conn_handle = nil
            print("Disconnect requested")
            if client_socket then client_socket:send("STATUS Disconnected\n") end
        end
    elseif action == "EXIT" then
        print("Exiting...")
        os.exit(0)
    end
end

-- =======================================================
-- Main
-- =======================================================
local function main()
    local ok, err = drop_privileges()
    if not ok then print("Error: " .. err); os.exit(1) end

    ok, err = init_bluetooth()
    if not ok then print("Error: " .. err); os.exit(1) end

    server_socket = socket.bind("127.0.0.1", 50010)
    server_socket:settimeout(0)
    print("Server listening on 127.0.0.1:50010")

    local poll_fds = ffi.new("struct pollfd[1]")
    local buffer = ffi.new("uint8_t[256]")

    while true do
        -- A. Accept Client
        if not client_socket then
            local client, err = server_socket:accept()
            if client then
                client_socket = client
                client_socket:settimeout(0)
                print("Client connected")
            end
        end

        -- B. Read Client Command
        if client_socket then
            local line, err = client_socket:receive()
            if line then
                print("CMD: " .. line)
                handle_command(line)
            elseif err == "closed" then
                print("Client disconnected")
                client_socket = nil
            end
        end

        -- C. Read Pipe (Notifications)
        -- We use poll to check if pipe has data
        poll_fds[0].fd = pipe_fds[0]
        poll_fds[0].events = ffi.C.POLLIN

        local ret = ffi.C.poll(poll_fds, 1, 50) -- 50ms timeout
        if ret > 0 and bit.band(poll_fds[0].revents, ffi.C.POLLIN) ~= 0 then
            -- Read Length (1 byte)
            local r = ffi.C.read(pipe_fds[0], buffer, 1)
            if r == 1 then
                local len = buffer[0]
                -- Read Data
                r = ffi.C.read(pipe_fds[0], buffer, len)
                if r == len then
                    -- Broadcast to client
                    if client_socket then
                        local hex = ""
                        for i=0, len-1 do
                            hex = hex .. string.format("%02X", buffer[i])
                        end
                        client_socket:send("NOTIFY " .. hex .. "\n")
                    end
                end
            end
        else
             -- if no pipe data, sleep a bit to save CPU (already slept 50ms in poll)
        end
    end
end

main()
