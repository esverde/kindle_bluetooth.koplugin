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
    local file = io.open(self.settings_file, "r")
    if not file then
        self:saveSettings()
        return
    end

    local content = file:read("*all")
    file:close()

    local loader = loadstring(content)
    if not loader then return end

    local user_config = loader()
    if not user_config then return end

    for key, value in pairs(user_config) do
        self.config[key] = value
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
    if not input then return false end

    local path = self.config.device_path

    -- Already connected
    if input.opened_devices and input.opened_devices[path] then
        return true
    end

    -- Check if device file exists
    if not self:deviceExists(path) then
        logger.info("BT Plugin: Device " .. path .. " not found (Controller off?)")
        return false
    end

    -- Attempt connection
    logger.warn("BT Plugin: Found device, connecting to " .. path)
    local success, err = pcall(function() input:open(path) end)

    if not success then
        logger.warn("BT Plugin: Failed to open -> " .. tostring(err))
    end

    return success
end

function BluetoothController:deviceExists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

function BluetoothController:reloadDevice()
    local input = Device.input
    if not input then return false end

    local path = self.config.device_path

    -- Close existing connection if open
    if input.opened_devices and input.opened_devices[path] then
        logger.warn("BT Plugin: Reload - Closing old connection " .. path)
        pcall(function() input:close(path) end)
    end

    -- Reopen device
    logger.warn("BT Plugin: Reload - Re-opening " .. path)
    local success = pcall(function() input:open(path) end)
    return success
end

-- =======================================================
--  硬件状态逻辑
-- =======================================================

function BluetoothController:getRealState()
    local success, output = pcall(function()
        local pipe = io.popen("lipc-get-prop com.lab126.btfd BTstate")
        if not pipe then return nil end
        local result = pipe:read("*all")
        pipe:close()
        return result
    end)

    if not success or not output then return false end

    return (tonumber(output) or 0) > 0
end

-- Returns cached state if within debounce window, otherwise queries hardware
function BluetoothController:getDisplayState()
    local elapsed = os.time() - self.last_action_time
    if elapsed < 2 then
        return self.target_state
    end
    return self:getRealState()
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
    local direction = self:parseInputDirection(ev)
    if not direction then return end

    -- Apply inversion if configured
    if self.config.invert_layout then
        direction = -direction
    end

    UIManager:sendEvent(Event:new("GotoViewRel", direction))
    ev.type = -1  -- Mark event as consumed
end

function BluetoothController:parseInputDirection(ev)
    -- Handle key press events
    if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
        return self.config.key_map[ev.code]
    end

    -- Handle joystick/axis events
    if ev.type == C.EV_ABS and ev.value ~= 0 then
        local axis_map = self.config.joy_map[ev.code]
        return axis_map and axis_map[ev.value]
    end

    return nil
end

-- =======================================================
--  菜单界面
-- =======================================================

function BluetoothController:addToMainMenu(menu_items)
    menu_items.bluetooth_controller = {
        text = _("蓝牙翻页器"),
        sorting_hint = "tools",
        sub_item_table = {
            -- 1. Bluetooth toggle
            {
                text = _("Toggle Bluetooth"),
                keep_menu_open = true,
                checked_func = function()
                    return self:getDisplayState()
                end,
                callback = function(touchmenu_instance)
                    local next_state = not self:getDisplayState()
                    self.target_state = next_state
                    self.last_action_time = os.time()
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
