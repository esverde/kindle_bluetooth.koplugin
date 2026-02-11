-- =======================================================
-- 设置 Lua 路径 (适配 KOReader 环境，精简版)
-- =======================================================
-- 仅保留核心路径: common(socket), libs, 和插件自身
package.path = "/mnt/us/koreader/common/?.lua;/mnt/us/koreader/?.lua;" .. package.path
package.cpath = "/mnt/us/koreader/common/socket/?.so;/mnt/us/koreader/libs/lib?.so;/mnt/us/koreader/libs/?.so;" .. package.cpath

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

-- ... (FFI Definitions remain unchanged) ...

local function init_bluetooth()
    print("Initializing Bluetooth...")

    -- Priority: Local ./libs/ -> System /mnt/us/koreader/libs/
    local local_lib_path = SCRIPT_DIR .. "libs/"
    local sys_lib_path = "/mnt/us/koreader/libs/"

    local kbt_paths = {
        local_lib_path .. "libkindlebt.so",
        sys_lib_path .. "libkindlebt.so"
    }

    local adp_paths = {
        local_lib_path .. "libkindlebt_adapter.so",
        sys_lib_path .. "libkindlebt_adapter.so"
    }

    local lib_kbt_loaded, lib_adapter_loaded = false, false

    -- Load KindleBT
    for _, path in ipairs(kbt_paths) do
        local ok, lib = pcall(ffi.load, path, true)
        if ok then
            print("Loaded KindleBT from: " .. path)
            lib_kbt = lib
            lib_kbt_loaded = true
            break
        end
    end
    if not lib_kbt_loaded then return false, "Failed to load libkindlebt.so. Searched: " .. table.concat(kbt_paths, ", ") end

    -- Load Adapter
    for _, path in ipairs(adp_paths) do
        local ok, lib = pcall(ffi.load, path)
        if ok then
            print("Loaded Adapter from: " .. path)
            lib_adapter = lib
            lib_adapter_loaded = true
            break
        end
    end
    if not lib_adapter_loaded then return false, "Failed to load libkindlebt_adapter.so. Searched: " .. table.concat(adp_paths, ", ") end

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
