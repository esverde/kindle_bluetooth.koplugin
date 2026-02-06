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

    -- State variables for Bluetooth toggle debouncing
    last_action_time = 0,
    target_state = false,

    -- Default configuration
    config = {
        device_path = "/dev/input/event6",
        invert_layout = false,
        use_analog_mode = true,  -- true = analog joystick, false = d-pad mode

        -- Key code mappings: positive = next page, negative = prev page
        key_map = {
            [304] = 1, [307] = 1, [310] = 1,
            [305] = -1, [308] = -1, [311] = -1,
        },
        -- D-pad mode: discrete axis values (codes 16=X, 17=Y)
        dpad_map = {
            [17] = { [1] = 1, [-1] = -1 },
            [16] = { [-1] = 1, [1] = -1 }
        },
        -- Analog mode: continuous axis values 0-65535 (codes 0=X, 1=Y)
        analog_map = {
            [1] = { axis = "Y", low_dir = -1, high_dir = 1 },  -- Y axis: up=prev, down=next
            [0] = { axis = "X", low_dir = 1, high_dir = -1 }   -- X axis: left=next, right=prev
        },
        analog_center = { [0] = 32768, [1] = 32768 },  -- Center value per axis
        center_deadzone = 0.05,  -- 5% dead zone around center (for stick drift tolerance)
        analog_threshold = 16384,  -- Trigger threshold from center
    },
    settings_file = DataStorage:getSettingsDir() .. "/bluetooth.lua",

    -- Runtime state for analog mode
    analog_axis_values = { [0] = 32768, [1] = 32768 },  -- Cache current axis values (X, Y)
    analog_triggered = false,  -- Global lock: true = waiting for return to center
}

function BluetoothController:init()
    if not Device:isKindle() then return end

    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    -- Prevent duplicate hook registration on reload
    self:registerInputHook()

    -- Attempt initial device connection
    self:ensureConnected()
end

-- =======================================================
--  Settings Management
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

-- Serializes config to file with indentation and sorted keys
function BluetoothController:saveSettings()
    local file = io.open(self.settings_file, "w")
    if not file then return end

    -- Recursive serializer with indentation
    local function serialize(obj, level)
        level = level or 0
        local indent = string.rep("    ", level)
        local next_indent = string.rep("    ", level + 1)

        if type(obj) == "table" then
            local result = "{\n"

            -- Collect and sort keys
            local keys = {}
            for k in pairs(obj) do table.insert(keys, k) end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)

            for _, k in ipairs(keys) do
                local v = obj[k]
                local key_str = type(k) == "number"
                    and "[" .. k .. "]"
                    or "[\"" .. tostring(k) .. "\"]"

                result = result .. next_indent .. key_str .. " = " .. serialize(v, level + 1) .. ",\n"
            end
            return result .. indent .. "}"
        elseif type(obj) == "string" then
            return string.format("%q", obj)
        else
            return tostring(obj)
        end
    end

    file:write("return " .. serialize(self.config))
    file:close()
end

-- =======================================================
--  Input Hook Management
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
--  Device Connection Management
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
--  Hardware State Management
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
--  Input Event Processing
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

    -- Handle axis events
    if ev.type == C.EV_ABS then
        if self.config.use_analog_mode then
            return self:parseAnalogInput(ev)
        else
            return self:parseDpadInput(ev)
        end
    end

    return nil
end

-- Parse D-pad discrete axis input (codes 16, 17 with values -1, 0, 1)
function BluetoothController:parseDpadInput(ev)
    if ev.value == 0 then return nil end
    local axis_map = self.config.dpad_map[ev.code]
    return axis_map and axis_map[ev.value]
end

-- Parse analog joystick input (codes 0, 1 with values 0-65535)
-- Uses global lock: must return to center before triggering again
function BluetoothController:parseAnalogInput(ev)
    local mapping = self.config.analog_map[ev.code]
    if not mapping then return nil end

    local center = self:getAxisCenter(ev.code)
    local threshold = self.config.analog_threshold or 16384

    -- Update cached axis value
    self.analog_axis_values[ev.code] = ev.value

    -- Check if joystick has returned to center (all axes within dead zone)
    if self.analog_triggered then
        if self:isJoystickCentered(threshold) then
            self.analog_triggered = false  -- Unlock for next movement
        end
        -- ALWAYS return nil when we were in triggered state
        -- This prevents the unlock event from also triggering a new page turn
        return nil
    end

    -- Calculate deviation from center for current axis
    local current_deviation = math.abs(ev.value - center)

    -- Must exceed threshold to trigger
    if current_deviation <= threshold then
        return nil  -- Within dead zone
    end

    -- Check if current axis is the dominant one
    if not self:isDominantAxis(ev.code, current_deviation) then
        return nil  -- Not dominant, ignore this axis
    end

    -- Determine direction based on value
    local direction
    if ev.value < center then
        direction = mapping.low_dir
    else
        direction = mapping.high_dir
    end

    -- Lock and trigger
    self.analog_triggered = true
    return direction
end

-- Get center value for an axis (supports per-axis calibration)
function BluetoothController:getAxisCenter(axis_code)
    local centers = self.config.analog_center
    if centers and centers[axis_code] then
        return centers[axis_code]
    end
    return 32768  -- Default center
end

-- Get center dead zone size (in raw value units)
function BluetoothController:getCenterDeadzone()
    local percent = self.config.center_deadzone or 0.05  -- Default 5%
    return math.floor(65535 * percent)  -- Convert percentage to raw units
end

-- Check if a value is within the center dead zone
function BluetoothController:isValueCentered(axis_code, value)
    local center = self:getAxisCenter(axis_code)
    local deadzone = self:getCenterDeadzone()
    return math.abs(value - center) <= deadzone
end

-- Check if all axes are within the center dead zone (joystick at center)
function BluetoothController:isJoystickCentered(threshold)
    local center_deadzone = self:getCenterDeadzone()
    -- Use the larger of threshold and center_deadzone for return-to-center check
    local effective_zone = math.max(threshold, center_deadzone)

    for code, value in pairs(self.analog_axis_values) do
        local center = self:getAxisCenter(code)
        if math.abs(value - center) > effective_zone then
            return false
        end
    end
    return true
end

-- Check if the given axis has the largest deviation from center
function BluetoothController:isDominantAxis(axis_code, deviation)
    local dominated = true

    for code, value in pairs(self.analog_axis_values) do
        if code ~= axis_code then
            local center = self:getAxisCenter(code)
            local other_deviation = math.abs(value - center)
            if other_deviation > deviation then
                dominated = false
                break
            end
        end
    end

    return dominated
end

-- =======================================================
--  Menu Interface
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
            -- 2. Invert direction
            {
                text = _("Invert Direction"),
                checked_func = function() return self.config.invert_layout end,
                callback = function()
                    self.config.invert_layout = not self.config.invert_layout
                    self:saveSettings()
                end
            },
            -- 3. Input mode selection
            {
                text = _("Joystick Mode"),
                sub_item_table = {
                    {
                        text = _("Analog Joystick"),
                        checked_func = function() return self.config.use_analog_mode end,
                        callback = function()
                            self.config.use_analog_mode = true
                            self.last_analog_direction = {}  -- Reset debounce state
                            self:saveSettings()
                        end
                    },
                    {
                        text = _("D-Pad"),
                        checked_func = function() return not self.config.use_analog_mode end,
                        callback = function()
                            self.config.use_analog_mode = false
                            self:saveSettings()
                        end
                    }
                }
            },
            -- 4. Reload device
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
