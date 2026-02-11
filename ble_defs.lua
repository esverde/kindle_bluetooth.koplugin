local ffi = require("ffi")

-- =======================================================
--  KindleBT 类型与结构体定义
--  基于 Sighery/kindlebt 项目头文件
-- =======================================================

ffi.cdef[[
    // 基本类型
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

    // 常量
    static const int ACEBT_STATUS_SUCCESS = 0;
    static const int ACEBT_SESSION_TYPE_GATT_CLIENT = 2;
    static const int ACEBT_GATT_SERVICE_TYPE_PRIMARY = 0;

    // UUID 结构体
    typedef struct {
        uint8_t value[16];
    } uuid_t;

    // 蓝牙地址
    typedef struct {
        uint8_t address[6];
    } bdAddr_t;

    // 连接参数
    typedef struct {
        int min_interval;
        int max_interval;
        int latency;
        int timeout;
        int supervision_timeout;
    } bleConnParam_t;

    // GATT Blob 值
    typedef struct {
        uint16_t size;
        uint16_t offset;
        uint8_t* data;
    } bleGattBlobValue_t;

    // GATT 记录
    typedef struct {
        uuid_t uuid;
        uint8_t attProp;
        uint16_t attPerm;
        uint16_t handle;
    } bleGattRecord_t;

    // GATT 描述符
    typedef struct {
        bleGattRecord_t gattRecord;
        bleGattBlobValue_t blobValue;
        bool is_set;
        bool is_notify;
        uint8_t desc_auth_retry;
        uint8_t write_type;
    } bleGattDescriptor_t;

    // GATT 特征值 (对齐 aceBT_bleGattCharacteristicsValue_t 布局)
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
        uint8_t format;
        bleGattRecord_t gattRecord;
        bleGattDescriptor_t gattDescriptor;
        uint8_t auth_retry;
        uint8_t read_auth_retry;
        uint8_t write_type;
        void* descList_first;
        void** descList_last;
        uint8_t multiDescCount;
    } bleGattCharacteristicsValue_t;

    // GATT 服务结构体
    typedef struct {
        bleGattServiceType_t serviceType;
        uuid_t uuid;
        uint16_t handle;
        uint16_t no_characteristics;
        uint16_t no_desc;
        uint16_t no_included_svc;
        void* incSvcList_first;
        void** incSvcList_last;
        void* charsList_first;
        void** charsList_last;
        bool continue_decleration;
    } bleGattsService_t;

    // =====================================================
    //  回调函数类型 (用于 LuaJIT FFI 回调)
    // =====================================================

    // GATT Client 通知回调
    typedef void (*notify_chars_cb_t)(bleConnHandle conn_handle,
                                      bleGattCharacteristicsValue_t chars_value);
    // 其他 GATT Client 回调类型
    typedef void (*service_discovered_cb_t)(bleConnHandle conn_handle, status_t status);
    typedef void (*read_chars_cb_t)(bleConnHandle conn_handle,
                                    bleGattCharacteristicsValue_t chars_value, status_t status);
    typedef void (*write_chars_cb_t)(bleConnHandle conn_handle,
                                     bleGattCharacteristicsValue_t chars_value, status_t status);
    typedef void (*get_db_cb_t)(bleConnHandle conn_handle,
                                bleGattsService_t* gatt_service, uint32_t no_svc);
    typedef void (*exec_write_cb_t)(bleConnHandle conn_handle, status_t status);
    typedef void (*service_registered_cb_t)(status_t status, int server_id);
    typedef void (*write_desc_cb_t)(bleConnHandle conn_handle,
                                    bleGattCharacteristicsValue_t chars_value, status_t status);
    typedef void (*read_desc_cb_t)(bleConnHandle conn_handle,
                                   bleGattCharacteristicsValue_t chars_value, status_t status);

    // GATT Client 回调结构体
    typedef struct {
        size_t size;
        void* on_service_registered;
        void* on_service_discovered;
        void* on_read_char;
        void* on_write_char;
        void* notify_characteristics_cb;
        void* on_write_desc;
        void* on_read_desc;
        void* on_get_db;
        void* on_exec_write;
    } bleGattClientCallbacks_t;

    // =====================================================
    //  libkindlebt.so 封装 API
    //  来自 Sighery/kindlebt 项目
    // =====================================================

    bool isBLESupported(void);

    status_t openSession(sessionType_t session_type, sessionHandle* session_handle);
    status_t closeSession(sessionHandle session_handle);

    status_t bleRegister(sessionHandle session_handle);
    status_t bleDeregister(sessionHandle session_handle);

    status_t bleRegisterGattClient(sessionHandle session_handle,
                                    bleGattClientCallbacks_t* callbacks);
    status_t bleDeregisterGattClient(sessionHandle session_handle);

    status_t bleConnect(sessionHandle session_handle, bleConnHandle* conn_handle,
                        bdAddr_t* p_device, bleConnParam_t conn_param,
                        bleConnRole_t conn_role, bleConnPriority_t conn_priority);
    status_t bleDisconnect(bleConnHandle conn_handle);

    status_t bleSetNotification(sessionHandle session_handle, bleConnHandle conn_handle,
                                 bleGattCharacteristicsValue_t chars_value, bool enable);

    status_t bleDiscoverAllServices(sessionHandle session_handle, bleConnHandle conn_handle);
    status_t bleGetDatabase(bleConnHandle conn_handle, bleGattsService_t* p_gatt_service);

    status_t bleReadCharacteristic(sessionHandle session_handle, bleConnHandle conn_handle,
                                    bleGattCharacteristicsValue_t chars_value);
    status_t bleWriteCharacteristic(sessionHandle session_handle, bleConnHandle conn_handle,
                                     bleGattCharacteristicsValue_t* chars_value,
                                     responseType_t request_type);

    // =====================================================
    //  Libc 辅助函数 (用于 pipe)
    // =====================================================
    typedef long ssize_t;
    int pipe(int pipefd[2]);
    ssize_t read(int fd, void *buf, size_t count);
    ssize_t write(int fd, const void *buf, size_t count);
    int close(int fd);
    int fcntl(int fd, int cmd, ...);
]]

-- =====================================================
--  工具函数
-- =====================================================

-- MAC 地址字符串 "XX:XX:XX:XX:XX:XX" -> bdAddr_t
local function str2addr(mac_str)
    local addr = ffi.new("bdAddr_t")
    local bytes = { mac_str:match("(%x%x):(%x%x):(%x%x):(%x%x):(%x%x):(%x%x)") }
    if #bytes == 6 then
        for i = 1, 6 do
            -- FIXED: Do not reverse bytes. Use Big Endian (Human Readable) order.
            -- Verified via test_ble_connect.lua
            addr.address[i-1] = tonumber(bytes[i], 16)
        end
    else
        error("无效的 MAC 地址格式: " .. tostring(mac_str))
    end
    return addr
end

-- UUID 字符串 -> uuid_t (简单实现)
local function str2uuid(uuid_str)
    local uuid = ffi.new("uuid_t")
    return uuid
end



-- =====================================================
--  加载 libkindlebt.so
-- =====================================================

local function load_kindlebt_lib()
    -- 直接加载库名，依赖 KOReader 启动脚本设置的 LD_LIBRARY_PATH
    -- 库文件应放置在 /mnt/us/koreader/libs/libkindlebt.so
    local ok, lib = pcall(ffi.load, "kindlebt")
    if ok then return lib end

    return nil, "加载 libkindlebt.so 失败 (请确保文件位于 /mnt/us/koreader/libs/)"
end

local kindlebt_lib, k_err = load_kindlebt_lib()

return {
    kindlebt = kindlebt_lib,
    C = ffi.C,
    utils = {
        str2uuid = str2uuid,
        str2addr = str2addr,
    },
    err = k_err,
    SERVICE_PORT = 50010,
}
