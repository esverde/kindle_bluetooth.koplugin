local ffi = require("ffi")

-- =======================================================
--  KindleBT C Library Definitions (Aligned with ACS/Darkroot)
-- =======================================================

ffi.cdef[[
    // Basic Types
    typedef void* sessionHandle;
    typedef void* bleConnHandle;
    typedef int status_t;
    typedef int state_t;
    typedef int sessionType_t;
    typedef int bleConnPriority_t;
    typedef int bleConnRole_t;
    typedef int bleGattAttributeFormat;
    typedef int bleGattServiceType_t;
    typedef int bondState_t;
    typedef int gattStatus_t;
    typedef int responseType_t;

    // Constants (Inferred or Standard)
    static const int ACEBT_STATUS_SUCCESS = 0;
    static const int ACEBT_SESSION_TYPE_GATT_CLIENT = 2;
    static const int ACEBT_GATT_SERVICE_TYPE_PRIMARY = 0;

    // UUID Structure
    typedef struct {
        uint8_t value[16];
    } uuid_t;

    // Bluetooth Address
    typedef struct {
        uint8_t address[6];
    } bdAddr_t;

    // Connection Parameters
    typedef struct {
        int min_interval;
        int max_interval;
        int latency;
        int timeout;
        int supervision_timeout;
    } bleConnParam_t;

    // GATT Blob Value (Used in Union)
    typedef struct {
        uint16_t size;
        uint16_t offset;
        uint8_t* data;
    } bleGattBlobValue_t;

    // GATT Record
    typedef struct {
        uuid_t uuid;
        uint8_t attProp;
        uint16_t attPerm;
        uint16_t handle;
    } bleGattRecord_t;

    // GATT Descriptor
     typedef struct {
        bleGattRecord_t gattRecord;
        bleGattBlobValue_t blobValue;
        bool is_set;
        bool is_notify;
        uint8_t desc_auth_retry;
        uint8_t write_type;
    } bleGattDescriptor_t;

    // GATT Characteristic Value
    // IMPORTANT: Matches aceBT_bleGattCharacteristicsValue_t layout
    typedef struct {
        union {
            uint8_t uint8Val;
            uint16_t uint16Val;
            uint32_t uint32Val;
            int8_t int8Val;
            int16_t int16Val;
            int32_t int32Val;
            bleGattBlobValue_t blobValue;
        };
        uint8_t format; // bleGattAttributeFormat
        bleGattRecord_t gattRecord;
        bleGattDescriptor_t gattDescriptor;
        uint8_t auth_retry;
        uint8_t read_auth_retry;
        uint8_t write_type;
        // struct gattDescList descList (STAILQ_HEAD = 2 pointers)
        void* descList_first;
        void** descList_last;
        uint8_t multiDescCount;
    } bleGattCharacteristicsValue_t;

     // GATT Service Structure
    typedef struct {
        bleGattServiceType_t serviceType;
        uuid_t uuid;
        uint16_t handle;
        uint16_t no_characteristics;
        uint16_t no_desc;
        uint16_t no_included_svc;
        // struct gattIncludedSvcList (2 pointers)
        void* incSvcList_first;
        void** incSvcList_last;
        // struct gattCharsList (2 pointers)
        void* charsList_first;
        void** charsList_last;
        bool continue_decleration;
    } bleGattsService_t;

    // Callback Function Types
    typedef void (*cb_void_t)(void);

    // GATT Client Callbacks Structure
    // MUST match aceBT_bleGattClientCallbacks_t layout exactly
    typedef struct {
        size_t size;
        void* on_service_registered;
        void* on_service_discovered;
        void* on_read_char;
        void* on_write_char;
        void* notify_characteristics_cb; // <--- This is what we use
        void* on_write_desc;
        void* on_read_desc;
        void* on_get_db;
        void* on_exec_write;
    } bleGattClientCallbacks_t;

    // API Functions
    status_t aceBT_openSession(sessionType_t type, sessionHandle* handle_out);
    status_t aceBT_closeSession(sessionHandle handle);

    status_t aceBT_bleRegisterGattClient(sessionHandle handle, bleGattClientCallbacks_t* callbacks);
    status_t aceBT_bleDeRegisterGattClient(sessionHandle handle);

    // Note: aceBt_bleConnect (with priority) vs aceBT_bleConnect (deprecated)
    // We use aceBt_bleConnect signature roughly
    status_t aceBt_bleConnect(sessionHandle handle, bdAddr_t* device, bleConnParam_t params, bleConnRole_t role, bool auto_connect, bleConnPriority_t priority);
    status_t aceBT_bleDisconnect(bleConnHandle conn_handle);

    // Helpers
    // Libc for pipe replacement
    typedef long ssize_t;
    int pipe(int pipefd[2]);
    ssize_t read(int fd, void *buf, size_t count);
    int close(int fd);
    int fcntl(int fd, int cmd, ...);
]]

-- Helper to create UUID from string (Simple 16-bit or 128-bit)
local function str2uuid(uuid_str)
    local uuid = ffi.new("uuid_t")
    -- Simple implementation: assuming 128-bit hex string for now
    return uuid
end

-- Helper to parse MAC address "XX:XX:XX:XX:XX:XX"
local function str2addr(mac_str)
    local addr = ffi.new("bdAddr_t")
    local bytes = { mac_str:match("(%x%x):(%x%x):(%x%x):(%x%x):(%x%x):(%x%x)") }
    if #bytes == 6 then
        for i = 1, 6 do
            addr.address[i-1] = tonumber(bytes[i], 16)
        end
    else
        error("Invalid MAC address format: " .. tostring(mac_str))
    end
    return addr
end

-- Helper to resolve plugin directory
local function get_plugin_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@(.+)")
    return script_path and script_path:match("(.+)/[^/]+/[^/]+$") or "."
end

-- Load KindleBT Library (Original)
local function load_kindlebt_lib()
    local plugin_dir = get_plugin_dir()
    local lib_path = plugin_dir .. "/lib/libkindlebt.so"

    local ok, lib = pcall(ffi.load, lib_path)
    if not ok then
        -- Try system load
        ok, lib = pcall(ffi.load, "kindlebt")
    end

    if not ok then
        return nil, "Failed to load libkindlebt.so from " .. lib_path
    end
    return lib
end

-- Load Adapter Library (Wrapper)
local function load_adapter_lib()
    local plugin_dir = get_plugin_dir()
    local lib_path = plugin_dir .. "/lib/libkindlebt_adapter.so"
    local ok, lib = pcall(ffi.load, lib_path)
    if not ok then
        return nil, "Failed to load libkindlebt_adapter.so from " .. lib_path
    end
    return lib
end

local kindlebt_lib, k_err = load_kindlebt_lib()
local adapter_lib, a_err = load_adapter_lib()

-- Add adapter functions to identifiers which are not in standard Headers
ffi.cdef[[
    void adapter_set_pipe(int fd);
    void adapter_get_callbacks(bleGattClientCallbacks_t *callbacks);
]]

return {
    kindlebt = kindlebt_lib,
    adapter = adapter_lib,
    lib = adapter_lib, -- Alias for backward compatibility
    C = ffi.C,
    utils = {
        str2uuid = str2uuid,
        str2addr = str2addr
    },
    err = k_err or a_err
}
