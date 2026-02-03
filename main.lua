local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local logger = require("logger")
local DataStorage = require("datastorage")
local _ = require("gettext")
local ffi = require("ffi")
local C = ffi.C

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    
    -- 蓝牙开关需要的状态变量
    last_action_time = 0,
    target_state = false,

    -- 默认配置
    config = {
        device_path = "/dev/input/event6",
        invert_layout = false,
        
        -- 按键映射
        key_map = {
            [304] = 1, [307] = 1, [310] = 1,
            [305] = -1, [308] = -1, [311] = -1,
        },
        -- 摇杆映射
        joy_map = {
            [17] = { [1] = 1, [-1] = -1 },
            [16] = { [-1] = 1, [1] = -1 }
        }
    },
    settings_file = DataStorage:getSettingsDir() .. "/bluetooth.lua",
}

function BluetoothController:init()
    if not Device:isKindle() then return end
    
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    
    -- 防止钩子重复叠加
    self:registerInputHook()
    
    -- 启动连接
    self:ensureConnected()
end

-- =======================================================
--  配置加载与保存
-- =======================================================

function BluetoothController:loadSettings()
    local f = io.open(self.settings_file, "r")
    if f then
        local c = f:read("*all")
        f:close()
        local func = loadstring(c)
        if func then
            local u = func()
            if u then for k,v in pairs(u) do self.config[k] = v end end
        end
    else
        self:saveSettings()
    end
end

-- 支持缩进和排序的保存函数
function BluetoothController:saveSettings()
    local f = io.open(self.settings_file, "w")
    if f then
        -- 递归序列化函数，带缩进层级
        local function serialize(o, level)
            level = level or 0
            local indent = string.rep("    ", level)
            local next_indent = string.rep("    ", level + 1)

            if type(o) == "table" then
                local s = "{\n"
                
                -- 获取所有 Key 并排序
                local keys = {}
                for k in pairs(o) do table.insert(keys, k) end
                table.sort(keys, function(a, b) 
                    return tostring(a) < tostring(b) 
                end)

                for _, k in ipairs(keys) do
                    local v = o[k]
                    local k_str
                    if type(k) == "number" then
                        k_str = "[" .. k .. "]"
                    else
                        k_str = "[\"" .. tostring(k) .. "\"]"
                    end
                    
                    s = s .. next_indent .. k_str .. " = " .. serialize(v, level + 1) .. ",\n"
                end
                return s .. indent .. "}"
            elseif type(o) == "string" then
                return string.format("%q", o)
            else
                return tostring(o)
            end
        end

        f:write("return " .. serialize(self.config))
        f:close()
    end
end

-- =======================================================
--  钩子管理逻辑
-- =======================================================

function BluetoothController:registerInputHook()
    if Device.input._bt_hook_ref then
        -- 针对没有自动清理的情况, 尝试从表中移除
        if Device.input.event_adjust_hooks then
            for i, hook in ipairs(Device.input.event_adjust_hooks) do
                if hook == Device.input._bt_hook_ref then
                    table.remove(Device.input.event_adjust_hooks, i)
                    logger.warn("BT Plugin: Manual reload detected - Cleaned up old hook")
                    break
                end
            end
        end
        Device.input._bt_hook_ref = nil
    end

    local hook_func = function(input_instance, ev)
        self:handleInputEvent(ev)
    end

    Device.input:registerEventAdjustHook(hook_func)
    Device.input._bt_hook_ref = hook_func
end

-- =======================================================
--  连接管理逻辑
-- =======================================================

function BluetoothController:ensureConnected()
    local input = Device.input
    local path = self.config.device_path
    if not input then return end

    -- 1. 如果已经连接了，直接退出
    if input.opened_devices and input.opened_devices[path] then
        return true
    end

    -- 2. 先检查设备文件是否存在
    local f = io.open(path, "r")
    if f then
        f:close()
    else
        -- 文件不存在，说明没开手柄。
        logger.info("BT Plugin: Device " .. path .. " not found (Controller off?)")
        return false
    end

    -- 3. 只有确认文件存在，才尝试从内核挂载
    logger.warn("BT Plugin: Found device, connecting to " .. path)
    local ok, err = pcall(function() input:open(path) end)
    
    if not ok then
        -- 只有当文件存在却打不开时，才打印报错
        logger.warn("BT Plugin: Failed to open -> " .. tostring(err))
    end
    
    return ok
end

function BluetoothController:reloadDevice()
    local input = Device.input
    local path = self.config.device_path
    if not input then return end
    
    if input.opened_devices and input.opened_devices[path] then
        logger.warn("BT Plugin: Reload - Closing old connection " .. path)
        pcall(function() input:close(path) end)
    end
    
    logger.warn("BT Plugin: Reload - Re-opening " .. path)
    local ok, err = pcall(function() input:open(path) end)
    
    return ok
end

-- =======================================================
--  硬件状态逻辑
-- =======================================================

function BluetoothController:getRealState()
    local status, result = pcall(function()
        local f = io.popen("lipc-get-prop com.lab126.btfd BTstate")
        if not f then return nil end
        local content = f:read("*all")
        f:close()
        return content
    end)
    if not status or not result then return false end
    local state = tonumber(result) or 0
    return state > 0
end

function BluetoothController:setBluetoothState(enable)
    local val = enable and 0 or 1
    os.execute(string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", val))
    local msg = enable and _("Bluetooth enabled") or _("Bluetooth disabled")
    UIManager:show(InfoMessage:new { text = msg, timeout = 2 })
end

function BluetoothController:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_kindle_bluetooth", {
        category = "none",
        event = "ToggleBluetooth",
        title = _("Toggle Kindle Bluetooth"),
        general = true
    })
end

-- =======================================================
--  输入处理逻辑
-- =======================================================

function BluetoothController:handleInputEvent(ev)
    local dir = nil

    if ev.type == C.EV_KEY then
        if ev.value == 1 or ev.value == 2 then
            local action = self.config.key_map[ev.code]
            if action then dir = action end
        end
    elseif ev.type == C.EV_ABS then
        if ev.value ~= 0 then
            local axis_map = self.config.joy_map[ev.code]
            if axis_map then
                local action = axis_map[ev.value]
                if action then dir = action end
            end
        end
    end

    if dir then
        -- 反转逻辑
        if self.config.invert_layout then
            dir = -dir
        end
        
        UIManager:sendEvent(Event:new("GotoViewRel", dir))
        ev.type = -1
    end
end

-- =======================================================
--  菜单界面
-- =======================================================

function BluetoothController:addToMainMenu(menu_items)
    menu_items.bluetooth_controller = {
        text = _("蓝牙翻页器"),
        sorting_hint = "tools",
        sub_item_table = {
            -- 1. 蓝牙开关
            {
                text = _("Toggle Bluetooth"),
                keep_menu_open = true,
                checked_func = function()
                    local now = os.time()
                    if (now - self.last_action_time) < 2 then return self.target_state
                    else return self:getRealState() end
                end,
                callback = function(touchmenu_instance)
                    local now = os.time()
                    local next_state
                    if (now - self.last_action_time) < 2 then next_state = not self.target_state
                    else next_state = not self:getRealState() end
                    self.target_state = next_state
                    self.last_action_time = now
                    touchmenu_instance:updateItems()
                    self:setBluetoothState(next_state)
                end,
            },
            -- 2. 颠倒方向
            {
                text = _("Invert Direction"),
                checked_func = function() return self.config.invert_layout end,
                callback = function()
                    self.config.invert_layout = not self.config.invert_layout
                    self:saveSettings()
                end
            },
            -- 3. 重载设备
            {
                text = _("Reload Device"),
                callback = function()
                    self:loadSettings()
                    if self:reloadDevice() then
                        UIManager:show(InfoMessage:new{ text = "Device loaded", timeout = 2 })
                    else
                        UIManager:show(InfoMessage:new{ text = "Failed to load", timeout = 2 })
                    end
                end
            }
        }
    }
end

return BluetoothController