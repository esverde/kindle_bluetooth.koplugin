local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")

local BLEManager = {
    service_socket = nil,
    input_handler_func = nil,
    is_connected = false,
}

-- 获取插件目录
local function get_plugin_dir()
    local str = debug.getinfo(1, "S").source:sub(2)
    return str:match("(.*/)")
end

function BLEManager:init(input_handler)
    self.input_handler_func = input_handler

        -- Start background service (Set LD_LIBRARY_PATH to include local libs)
        local plugin_dir = get_plugin_dir()
        local luajit_cmd = "/mnt/us/koreader/luajit"

        local cmd = "export LD_LIBRARY_PATH=" .. plugin_dir .. "libs:/mnt/us/koreader/libs:$LD_LIBRARY_PATH && " .. luajit_cmd .. " " .. plugin_dir .. "ble_service.lua > /dev/null 2>&1 &"

        logger.info("BLE Manager: Launching service")
        os.execute(cmd)

        -- 等待服务启动 (简单的延时重试)
        UIManager:scheduleIn(1, function()
            self:retryConnect(5)
        end)
    else
        logger.info("BLE Manager: 已连接到现有服务")
        self:setupClient(client)
    end
end

function BLEManager:retryConnect(retries)
    local client = socket.connect("127.0.0.1", 50010)
    if client then
        logger.info("BLE Manager: 服务启动成功并已连接")
        self:setupClient(client)
    else
        if retries > 0 then
            logger.warn("BLE Manager: 连接失败，重试剩余 " .. retries)
            UIManager:scheduleIn(1, function()
                self:retryConnect(retries - 1)
            end)
        else
            -- logger.error doesn't exist in some KR versions
            logger.warn("BLE Manager: 无法启动或连接蓝牙服务")
            Notification:new({
                text = "蓝牙服务启动失败",
                timeout = 3
            }):show()
        end
    end
end


function BLEManager:setupClient(client)
    self.service_socket = client
    self.service_socket:settimeout(0) -- 非阻塞
    self.is_connected = true

    -- 启动接收循环
    -- 在 KOReader 中通常使用 UIManager:scheduleIn 来轮询，或者集成到 copas
    -- 这里我们使用简单的 100ms 轮询
    self:pollLoop()
end

function BLEManager:pollLoop()
    if not self.service_socket then return end

    while true do
        local line, err = self.service_socket:receive()
        if line then
            self:handleServiceMessage(line)
        else
            if err == "closed" then
                logger.warn("BLE Manager: 服务断开")
                self.service_socket = nil
                self.is_connected = false
                return
            end
            break -- timeout / no data
        end
    end

    -- 继续轮询
    UIManager:scheduleIn(0.1, function()
        self:pollLoop()
    end)
end

function BLEManager:handleServiceMessage(msg)
    -- 格式: NOTIFY <HEX_DATA>
    local cmd, data = msg:match("(%w+)%s*(.*)")
    if cmd == "NOTIFY" then
        -- 解析 HEX
        local bytes = {}
        for i=1, #data, 2 do
            table.insert(bytes, tonumber(data:sub(i,i+1), 16))
        end
        -- 触发回调
        if self.input_handler_func then
            self.input_handler_func(bytes)
        end
    end
end

function BLEManager:connect(mac)
    if not self.service_socket then
        logger.warn("BLE Manager: 未连接服务")
        return false
    end
    self.service_socket:send("CONNECT " .. mac .. "\n")
    return true
end

function BLEManager:disconnect()
    if self.service_socket then
        self.service_socket:send("DISCONNECT\n")
    end
end

return BLEManager
