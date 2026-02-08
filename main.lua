local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local logger = require("logger")
local DataStorage = require("datastorage")
local time = require("ui/time")
local _ = require("gettext")
local ffi = require("ffi")
local C = ffi.C

-- Constants
local AXIS_CENTER_DEFAULT = 32768
local AXIS_THRESHOLD_DEFAULT = 16384
local AXIS_MAX_VALUE = 65535
local TRIGGER_COOLDOWN_MS = 500

-- MODULE-LEVEL shared state (persists across all instances)
-- This is critical because KOReader may create multiple plugin instances
local _shared_last_trigger_time = nil  -- Time of last page turn
local _shared_hook_registered = false  -- Whether hook has been registered
local _shared_triggered = false  -- Whether joystick has triggered (must return to center to reset)
local _shared_axis_values = {}  -- Track all axis values for all-axes-centered check

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    is_doc_only = false,

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
        analog_center = { [0] = AXIS_CENTER_DEFAULT, [1] = AXIS_CENTER_DEFAULT },  -- Center value per axis
        analog_threshold = AXIS_THRESHOLD_DEFAULT,  -- Trigger threshold from center
    },
    settings_file = nil,  -- Dynamically set in getPluginDir()

    -- Hook activity state (per-instance, allows disabling without unregistering)
    _hook_active = true,
}

function BluetoothController:init()
    if not Device:isKindle() then return end

    -- Set settings file path to plugin directory
    self.settings_file = self:getPluginDir() .. "/bluetooth.lua"

    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    -- Prevent duplicate hook registration on reload
    self:registerInputHook()

    -- Attempt initial device connection
    self:ensureConnected()
end

-- =======================================================
--  Plugin Directory Detection
-- =======================================================

function BluetoothController:getPluginDir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@(.+)")
    if script_path then
        return script_path:match("(.+)/[^/]+$") or script_path:match("(.+)\\[^\\]+$") or "."
    end
    return "."
end

-- =======================================================
--  Settings Management
-- =======================================================

function BluetoothController:loadSettings()
    local file = io.open(self.settings_file, "r")
    if not file then
        logger.warn("BT Plugin: Config file not found, using defaults")
        return
    end

    local content = file:read("*all")
    file:close()

    local loader = loadstring(content)
    if not loader then
        logger.warn("BT Plugin: Failed to parse config file")
        return
    end

    local full_config = loader()
    if not full_config then return end

    -- Load common settings
    if full_config.common then
        self.wakeup_delay = full_config.common.wakeup_delay or 3
        self.config.invert_layout = full_config.common.invert_layout or false
        self.active_profile = full_config.common.active_profile or "xbox_wireless_controller"
    end

    -- Load active profile configuration
    if full_config.profiles and full_config.profiles[self.active_profile] then
        local profile = full_config.profiles[self.active_profile]

        -- Merge profile settings into self.config
        self.config.device_path = profile.device_path
        self.config.supports_dpad = profile.supports_dpad
        self.config.use_analog_mode = profile.use_analog_mode
        self.config.key_map = profile.key_map
        self.config.dpad_map = profile.dpad_map
        self.config.analog_map = profile.analog_map

        -- Set analog center values per axis
        if profile.analog_center then
            self.config.analog_center = profile.analog_center
        else
            local center = profile.axis_center or AXIS_CENTER_DEFAULT
            self.config.analog_center = { [0] = center, [1] = center }
        end

        self.config.analog_threshold = profile.axis_threshold or AXIS_THRESHOLD_DEFAULT

        logger.info("BT Plugin: Loaded profile '" .. (profile.name or self.active_profile) .. "'")
    else
        logger.warn("BT Plugin: Profile '" .. tostring(self.active_profile) .. "' not found")
    end

    -- Store full config for menu access
    self.full_config = full_config
end

-- Save full configuration back to file
function BluetoothController:saveFullConfig()
    if not self.full_config then return end

    local file = io.open(self.settings_file, "w")
    if not file then
        logger.warn("BT Plugin: Failed to open config file for writing")
        return
    end

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

    file:write("return " .. serialize(self.full_config))
    file:close()
    logger.info("BT Plugin: Configuration saved")
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

-- Register input event hook
-- Note: KOReader uses function chaining for hooks and doesn't support unregistration.
-- We use a flag-based approach to control whether our hook is active.
function BluetoothController:registerInputHook()
    -- Only register once per KOReader session (module-level check)
    if _shared_hook_registered then
        self._hook_active = true  -- Re-activate if previously disabled
        return
    end

    local controller = self  -- Capture reference for closure
    local hook_func = function(input_instance, ev)
        -- Only process events when hook is active
        if controller._hook_active then
            controller:handleInputEvent(ev)
        end
    end

    Device.input:registerEventAdjustHook(hook_func)
    _shared_hook_registered = true
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

    -- Reset shared state on new connection
    _shared_axis_values = {}
    _shared_triggered = false

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

    -- Reset shared state on reload
    _shared_axis_values = {}
    _shared_triggered = false

    local success = pcall(function() input:open(path) end)
    return success
end

-- Scan for JOYSTICK devices from KOReader's device registry
function BluetoothController:scanJoystickDevices()
    local devices = {}
    local input = Device.input

    if not input then
        logger.warn("BT Plugin: Device.input not available")
        return devices
    end

    -- KOReader's input system stores device info in dev_mod table
    -- Each entry contains device capabilities (e.g., "JOYSTICK", "KEY", etc.)
    if input.dev_mod then
        for dev_path, dev_info in pairs(input.dev_mod) do
            -- Check if device has JOYSTICK capability
            if dev_info and type(dev_info) == "table" then
                local is_joystick = false
                local device_name = dev_info.name or "Unknown Device"

                -- dev_info contains capability flags like isJoystick, isKeyboard, etc.
                if dev_info.isJoystick then
                    is_joystick = true
                end

                if is_joystick then
                    table.insert(devices, {
                        path = dev_path,
                        name = device_name,
                        connected = true
                    })
                    logger.info("BT Plugin: Found JOYSTICK device: " .. device_name .. " at " .. dev_path)
                end
            end
        end
    end

    return devices
end

-- =======================================================
--  Hardware State Management
-- =======================================================

function BluetoothController:getRealState()
    local success, output = pcall(function()
        -- Query Bluetooth radio state (BTstate: 0=off, >0=on)
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
    local val = enable and 0 or 1  -- BTflightMode: 0 = BT on, 1 = BT off
    local cmd = string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", val)
    -- In Lua 5.1, os.execute returns exit status (0 = success), not boolean
    local exit_code = os.execute(cmd)

    if exit_code ~= 0 then
        logger.warn("BT Plugin: Failed to execute: " .. cmd .. " (exit code: " .. tostring(exit_code) .. ")")
    end

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
--  System Event Handlers
-- =======================================================

function BluetoothController:onOutOfScreenSaver()
    logger.info("BT Plugin: Device wakeup detected, scheduling reload...")
    -- Use configured wakeup delay (default 3s) to allow Bluetooth stack to recover/reconnect
    local delay = self.wakeup_delay or 3
    UIManager:scheduleIn(delay, function()
        -- Only attempt reload if device file exists (controller is connected)
        if self:deviceExists(self.config.device_path) then
            logger.info("BT Plugin: Wakeup - Device found, reloading...")
            if self:reloadDevice() then
                UIManager:show(InfoMessage:new{ text = _("BT Controller Reconnected"), timeout = 2 })
            end
        else
            logger.info("BT Plugin: Wakeup - Device not found, skipping reload")
        end
    end)
end

-- =======================================================
--  Input Event Processing
-- =======================================================

function BluetoothController:handleInputEvent(ev)
    local direction = self:parseInputDirection(ev)
    if not direction then return end

    if self.config.invert_layout then
        direction = -direction
    end

    UIManager:sendEvent(Event:new("GotoViewRel", direction))
    ev.type = -1 -- Consume event
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
-- Uses COMBINED debouncing: state-based (must return to center) + time-based (cooldown)
-- Parse analog joystick input (codes 0, 1 with values 0-65535)
-- Uses COMBINED debouncing: state-based (must return to deadzone) + time-based
function BluetoothController:parseAnalogInput(ev)
    local mapping = self.config.analog_map[ev.code]
    if not mapping then return nil end

    local center = self:getAxisCenter(ev.code)
    local threshold = self.config.analog_threshold or AXIS_THRESHOLD_DEFAULT
    local deviation = math.abs(ev.value - center)

    _shared_axis_values[ev.code] = deviation

    -- Check if within dead zone
    if deviation <= threshold then
        -- Only reset triggered state if ALL mapped axes are in dead zone
        if _shared_triggered then
            local all_centered = true
            for axis_code, axis_deviation in pairs(_shared_axis_values) do
                if self.config.analog_map[axis_code] and axis_deviation > threshold then
                    all_centered = false
                    break
                end
            end
            if all_centered then
                _shared_triggered = false
            end
        end
        return nil
    end

    -- State-based debouncing: must have returned to center
    if _shared_triggered then return nil end

    -- Time-based debouncing: check cooldown
    local now = time:now()
    local now_ms = time.to_ms(now)

    if _shared_last_trigger_time then
        local last_ms = time.to_ms(_shared_last_trigger_time)
        if (now_ms - last_ms) < TRIGGER_COOLDOWN_MS then
            return nil
        end
    end

    -- Trigger action
    _shared_triggered = true
    _shared_last_trigger_time = now

    if ev.value < center then
        return mapping.low_dir
    else
        return mapping.high_dir
    end
end

-- Get center value for an axis (supports per-axis calibration)
function BluetoothController:getAxisCenter(axis_code)
    local centers = self.config.analog_center
    if centers and centers[axis_code] then
        return centers[axis_code]
    end
    return AXIS_CENTER_DEFAULT
end

-- =======================================================
--  Menu Interface
-- =======================================================

function BluetoothController:addToMainMenu(menu_items)
    menu_items.bluetooth_controller = {
        text = _("BluetoothController"),
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

            -- 2. Connected Devices
            {
                text = _("Connected Devices"),
                keep_menu_open = true,
                callback = function()
                    local devices = self:scanJoystickDevices()
                    local current_device = self.config.device_path

                    local msg = _("Detected JOYSTICK Devices:\n\n")
                    if #devices == 0 then
                        msg = msg .. _("No JOYSTICK devices found")
                    else
                        for _, dev in ipairs(devices) do
                            local status = (dev.path == current_device) and "[ACTIVE]" or ""
                            msg = msg .. string.format("%s %s\n%s\n\n", status, dev.name, dev.path)
                        end
                    end

                    UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
                end,
            },

            -- 3. Switch Profile
            {
                text = _("Switch Profile"),
                keep_menu_open = true,
                sub_item_table_func = function()
                    local profiles = {}

                    if self.full_config and self.full_config.profiles then
                        for profile_id, profile in pairs(self.full_config.profiles) do
                            table.insert(profiles, {
                                text = profile.name or profile_id,
                                checked_func = function()
                                    return self.active_profile == profile_id
                                end,
                                callback = function()
                                    -- Update active profile
                                    self.active_profile = profile_id

                                    -- Save to config file
                                    if self.full_config and self.full_config.common then
                                        self.full_config.common.active_profile = profile_id
                                        self:saveFullConfig()
                                    end

                                    -- Reload settings and device
                                    self:loadSettings()
                                    if self:reloadDevice() then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Switched to ") .. (profile.name or profile_id),
                                            timeout = 2
                                        })
                                    else
                                        UIManager:show(InfoMessage:new{
                                            text = _("Profile switched, but device not found"),
                                            timeout = 2
                                        })
                                    end
                                end,
                            })
                        end
                    end

                    return profiles
                end,
            },

            -- 4. Invert direction
            {
                text = _("Invert Direction"),
                checked_func = function() return self.config.invert_layout end,
                callback = function()
                    self.config.invert_layout = not self.config.invert_layout

                    -- Save to full config
                    if self.full_config and self.full_config.common then
                        self.full_config.common.invert_layout = self.config.invert_layout
                        self:saveFullConfig()
                    end
                end
            },
            -- 5. Joystick Mode (only show if controller supports D-Pad)
            {
                text = _("Joystick Mode"),
                enabled_func = function()
                    return self.config.supports_dpad == true
                end,
                sub_item_table = {
                    {
                        text = _("Analog Joystick"),
                        checked_func = function() return self.config.use_analog_mode end,
                        callback = function()
                            self.config.use_analog_mode = true
                            _shared_triggered = false  -- Reset lock state

                            -- Save to full config
                            if self.full_config and self.full_config.profiles and self.active_profile then
                                local profile = self.full_config.profiles[self.active_profile]
                                if profile then
                                    profile.use_analog_mode = true
                                    self:saveFullConfig()
                                end
                            end
                        end
                    },
                    {
                        text = _("D-Pad"),
                        checked_func = function() return not self.config.use_analog_mode end,
                        callback = function()
                            self.config.use_analog_mode = false

                            -- Save to full config
                            if self.full_config and self.full_config.profiles and self.active_profile then
                                local profile = self.full_config.profiles[self.active_profile]
                                if profile then
                                    profile.use_analog_mode = false
                                    self:saveFullConfig()
                                end
                            end
                        end
                    }
                }
            },

            -- 6. Wakeup Delay
            {
                text = _("Wakeup Delay"),
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    local current_delay = self.wakeup_delay or 3
                    UIManager:show(SpinWidget:new{
                        title_text = _("Set Wakeup Delay (seconds)"),
                        info_text = _("Delay before reconnecting controller after wakeup"),
                        value = current_delay,
                        value_min = 1,
                        value_max = 10,
                        value_step = 1,
                        value_hold_step = 2,
                        ok_text = _("Set"),
                        callback = function(spin)
                            self.wakeup_delay = spin.value

                            -- Save to full config
                            if self.full_config and self.full_config.common then
                                self.full_config.common.wakeup_delay = spin.value
                                self:saveFullConfig()
                            end

                            UIManager:show(InfoMessage:new{
                                text = _("Wakeup delay set to ") .. spin.value .. _(" seconds"),
                                timeout = 2
                            })
                        end
                    })
                end,
            },
            -- 7. Reload device
            {
                text = _("Reload Device"),
                callback = function()
                    self:loadSettings()
                    if self:reloadDevice() then
                        UIManager:show(InfoMessage:new{ text = _("Device loaded"), timeout = 2 })
                    else
                        UIManager:show(InfoMessage:new{ text = _("Failed to load"), timeout = 2 })
                    end
                end
            }
        }
    }
end

return BluetoothController
