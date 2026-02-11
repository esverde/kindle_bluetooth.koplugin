local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Event = require("ui/event")
local logger = require("logger")
local DataStorage = require("datastorage")
local time = require("ui/time")
local _ = require("gettext")
local ffi = require("ffi")

-- Add plugin directory to package.path to ensure we can require 'ble.manager'
local function setup_plugin_path()
    local info = debug.getinfo(1, "S")
    local source = info.source
    -- Handle @/path/to/script.lua structure
    local base_dir = source:match("@(.*/)")
    if base_dir then
        package.path = base_dir .. "?.lua;" .. package.path
    end
end
setup_plugin_path()

local C = ffi.C
local BLEManager = nil
-- Use pcall to load BLE manager so failure doesn't crash the whole plugin
local status, valid_manager_or_err = pcall(require, "ble_manager")
if status and valid_manager_or_err then
    BLEManager = valid_manager_or_err
else
    logger.warn("BT Plugin: Failed to load ble.manager: " .. tostring(valid_manager_or_err))
end


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

    -- Configuration loaded from bluetooth.lua
    config = {},
    full_config = {},
    settings_file = nil,  -- Dynamically set in getPluginDir()

    -- Hook activity state (per-instance, allows disabling without unregistering)
    _hook_active = true,
}

function BluetoothController:init()
    if not Device:isKindle() then return end

    local plugin_dir = self:getPluginDir()
    self.settings_file = plugin_dir .. "/bluetooth.lua"

    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    -- Prevent duplicate hook registration on reload
    self:registerInputHook()

    -- Always initialize BLE Manager if available (Mixed Mode)
    if BLEManager then
        BLEManager:init(function(data) self:handleBLEInput(data) end)
    end

    -- Attempt initial device connection (Classic / Configured BLE)
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
        self.trigger_cooldown_ms = full_config.common.trigger_cooldown_ms or 500
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
        self.config.analog_center = profile.analog_center
        self.config.analog_map = profile.analog_map
        self.config.analog_center = profile.analog_center
        self.config.analog_threshold = profile.axis_threshold
        self.config.protocol = profile.protocol or "classic"
        self.config.mac_address = profile.mac_address

        logger.info("BT Plugin: Loaded profile '" .. (profile.name or self.active_profile) .. "'")
    else
        logger.warn("BT Plugin: Profile '" .. tostring(self.active_profile) .. "' not found in bluetooth.lua")
        logger.warn("BT Plugin: Please ensure bluetooth.lua exists and contains valid profile configuration")
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
    -- Branch logic based on protocol
    if self.config.protocol == "ble" then
        if BLEManager then
             return BLEManager:connect(self.config.mac_address)
        else
             logger.warn("BT Plugin: BLE Manager not loaded")
             return false
        end
    end

    -- Classic Logic
    local path = self.config.device_path
    if self:isDeviceOpened(path) then return true end

    -- Check if device file exists
    if not self:deviceExists(path) then
        logger.info("BT Plugin: Device " .. path .. " not found")
        return false
    end

    local success, err = self:_attemptOpenDevice(path)
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

-- Helper: encapsulate critical section for opening device
function BluetoothController:_attemptOpenDevice(path)
    local input = Device.input
    if not input then return false, "No Input Module" end

    -- Reset shared state on new connection
    _shared_axis_values = {}
    _shared_triggered = false

    local success, err = pcall(function() input:open(path) end)

    if success then
        self:cleanupBluetoothDumps()
    end

    return success, err
end

function BluetoothController:reloadDevice()
    local path = self.config.device_path
    if not path or path == "" then
        logger.warn("BT Plugin: No device path configured")
        return false
    end

    local input = Device.input

    -- Close if already open
    if self:isDeviceOpened(path) then
        logger.warn("BT Plugin: Reload - Closing old connection " .. path)
        pcall(function() input:close(path) end)
    end

    -- Reset shared state on reload
    _shared_axis_values = {}
    _shared_triggered = false

    local success = pcall(function() input:open(path) end)

    -- Auto cleanup dump files after successful reload
    if success then
        self:cleanupBluetoothDumps()
    end

    return success
end

-- Scan for JOYSTICK devices from KOReader's device registry
function BluetoothController:scanJoystickDevices()
    local devices = {}
    local input = Device.input

    if not input or not input.opened_devices then
        logger.warn("BT Plugin: Device.input or opened_devices not available")
        return devices
    end

    -- Check opened_devices for joystick devices
    for dev_path, _ in pairs(input.opened_devices) do
        local event_num = dev_path:match("/dev/input/event(%d+)")
        if event_num then
            -- Read device name from sysfs
            local sys_name_path = "/sys/class/input/event" .. event_num .. "/device/name"
            local name_file = io.open(sys_name_path, "r")
            local device_name = "Unknown Device"

            if name_file then
                device_name = name_file:read("*line") or device_name
                name_file:close()
            end

            -- Check if this is a joystick device
            local is_joystick = false

            -- Method 1: Match against configured profiles
            if self.full_config and self.full_config.profiles then
                for _, profile in pairs(self.full_config.profiles) do
                    if profile.device_path == dev_path then
                        is_joystick = true
                        -- Don't override device_name - use actual name from sysfs
                        break
                    end
                end
            end

            -- Method 2: Match by device name patterns (fallback)
            if not is_joystick then
                if device_name:match("Controller") or device_name:match("Gamepad") or
                   device_name:match("Joystick") or device_name:match("Xbox") or
                   device_name:match("PlayStation") then
                    is_joystick = true
                end
            end

            if is_joystick then
                table.insert(devices, {
                    path = dev_path,
                    name = device_name,  -- Always use actual device name from sysfs
                    connected = true
                })
                logger.info("BT Plugin: Found JOYSTICK device: " .. device_name .. " at " .. dev_path)
            end
        end
    end

    return devices
end

-- Check if a device is currently opened
function BluetoothController:isDeviceOpened(path)
    local input = Device.input
    if input and input.opened_devices then
        return input.opened_devices[path] ~= nil
    end
    return false
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

-- =======================================================
--  BLE Handling
-- =======================================================

function BluetoothController:handleBLEInput(data)
    if not data or #data < 2 then return end

    -- Assuming Standard Gamepad Report: [LeftX, LeftY, RightX, RightY, Buttons...]
    -- Map to Linux Event Codes (ABS_X=0, ABS_Y=1)

    -- Byte 1: X Axis (0-255) -> Map to signed (-128..127) for handleInputEvent
    local raw_x = string.byte(data, 1) or 128
    local val_x = raw_x - 128

    -- Byte 2: Y Axis (0-255)
    local raw_y = string.byte(data, 2) or 128
    local val_y = raw_y - 128

    -- Construct Virtual Events
    local ev_x = { type = C.EV_ABS, code = 0, value = val_x }
    local ev_y = { type = C.EV_ABS, code = 1, value = val_y }

    -- Process Events
    self:handleInputEvent(ev_x)
    self:handleInputEvent(ev_y)
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
        local cooldown_ms = (self.trigger_cooldown_ms or 500)  -- Default 500ms if not configured
        if (now_ms - last_ms) < cooldown_ms then
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
--  Bluetooth Dump File Cleanup
-- =======================================================

-- Clean up Bluetooth-related dump files
function BluetoothController:cleanupBluetoothDumps()
    local total_deleted = 0

    -- Define cleanup targets with safe, specific patterns
    local cleanup_paths = {
        {
            dir = "/mnt/us",
            patterns = {
                "audiomgrd_*.core",
                "btmanagerd_*.core",
                "Indexer_Dump_*.txt"
            }
        },
        {
            dir = "/mnt/us/documents",
            patterns = {
                "audiomgrd_*_crash_*.tgz",
                "audiomgrd_*_crash_*.txt",
                "btmanagerd_*_crash_*.tgz",
                "btmanagerd_*_crash_*.txt",
                "audiomgrd_*_crash_*.sdr",
                "btmanagerd_*_crash_*.sdr"
            }
        }
    }

    -- Clean up files matching patterns
    for _, path_config in ipairs(cleanup_paths) do
        local dir = path_config.dir
        for _, pattern in ipairs(path_config.patterns) do
            -- Use find command to locate and count matching files
            local find_cmd = string.format("find '%s' -maxdepth 1 -name '%s' 2>/dev/null", dir, pattern)
            local pipe = io.popen(find_cmd)
            if pipe then
                local files = {}
                for file in pipe:lines() do
                    table.insert(files, file)
                end
                pipe:close()

                -- Delete each file/directory
                for _, file in ipairs(files) do
                    local rm_cmd = string.format("rm -rf '%s' 2>/dev/null", file)
                    local success = os.execute(rm_cmd)
                    if success == 0 or success == true then
                        total_deleted = total_deleted + 1
                        logger.info("BT Plugin: Deleted dump file: " .. file)
                    end
                end
            end
        end
    end

    logger.info("BT Plugin: Cleanup completed, deleted " .. total_deleted .. " files/folders")
    return total_deleted
end

-- =======================================================
--  Menu Interface
-- =======================================================

function BluetoothController:addToMainMenu(menu_items)
    local sub_items = {}

    self:_addBluetoothToggle(sub_items)
    self:_addDeviceList(sub_items)
    self:_addCommonOptions(sub_items)
    self:_addUtilityOptions(sub_items)

    menu_items.bluetooth_controller = {
        text = _("蓝牙翻页器"),
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

-- Menu Helper: Bluetooth Toggle
function BluetoothController:_addBluetoothToggle(sub_items)
    table.insert(sub_items, {
        text = _("蓝牙开关"),
        keep_menu_open = true,
        checked_func = function() return self:getDisplayState() end,
        callback = function(touchmenu_instance)
            local next_state = not self:getDisplayState()
            self.target_state = next_state
            self.last_action_time = os.time()
            touchmenu_instance:updateItems()
            self:setBluetoothState(next_state)
        end,
    })
end

-- Menu Helper: Device List (Unified)
function BluetoothController:_addDeviceList(sub_items)
    if not (self.full_config and self.full_config.profiles) then return end

    -- Sort profiles
    local sorted_profiles = {}
    for id, profile in pairs(self.full_config.profiles) do
        table.insert(sorted_profiles, {id = id, profile = profile})
    end
    table.sort(sorted_profiles, function(a, b)
        return (a.profile.name or a.id) < (b.profile.name or b.id)
    end)

    for _, item in ipairs(sorted_profiles) do
        local profile_id = item.id
        local profile = item.profile
        local name = profile.name or profile_id

        -- Determine display label
        local is_ble_connection = (profile.protocol == "ble") or (profile.mac_address and profile.mac_address ~= "")
        local label_prefix = is_ble_connection and "BLE: " or "Classic: "

        table.insert(sub_items, {
            text = _(label_prefix) .. name,
            checked_func = function() return self.active_profile == profile_id end,
            callback = function()
                self:activateProfile(profile_id, profile, name)
            end
        })
    end
end

-- Helper to activate a profile logic
function BluetoothController:activateProfile(profile_id, profile, name)
    self.active_profile = profile_id
    if self.full_config and self.full_config.common then
        self.full_config.common.active_profile = profile_id
        self:saveFullConfig()
    end
    self:loadSettings()

    -- 1. Connection Phase (if BLE MAC provided)
    if profile.mac_address and profile.mac_address ~= "" then
        if BLEManager then
            BLEManager:connect(profile.mac_address)
            UIManager:show(InfoMessage:new{ text = _("正在连接 BLE..."), timeout = 1 })
        else
            UIManager:show(InfoMessage:new{ text = _("BLE服务不可用"), timeout = 2 })
        end
    end

    -- 2. Input Phase (Unified)
    UIManager:scheduleIn(1, function()
        if self:reloadDevice() then
            UIManager:show(InfoMessage:new{ text = _("已加载设备: ") .. name, timeout = 2 })
        else
            UIManager:show(InfoMessage:new{ text = _("未找到输入设备 (可能需重试): ") .. name, timeout = 2 })
        end
    end)
end

-- Menu Helper: Common Options
function BluetoothController:_addCommonOptions(sub_items)
    -- Invert direction
    table.insert(sub_items, {
        text = _("反转方向"),
        checked_func = function() return self.config.invert_layout end,
        callback = function()
            self.config.invert_layout = not self.config.invert_layout
            if self.full_config and self.full_config.common then
                self.full_config.common.invert_layout = self.config.invert_layout
                self:saveFullConfig()
            end
        end
    })

    -- Wakeup Delay
    table.insert(sub_items, {
        text = _("唤醒延迟"),
        keep_menu_open = true,
        callback = function()
            local SpinWidget = require("ui/widget/spinwidget")
            local current_delay = self.wakeup_delay or 3
            UIManager:show(SpinWidget:new{
                title_text = _("设置唤醒延迟（秒）"),
                value = current_delay,
                value_min = 1,
                value_max = 10,
                value_step = 1,
                value_hold_step = 2,
                ok_text = _("确定"),
                callback = function(spin)
                    self.wakeup_delay = spin.value
                    if self.full_config and self.full_config.common then
                        self.full_config.common.wakeup_delay = spin.value
                        self:saveFullConfig()
                    end
                    UIManager:show(InfoMessage:new{text = _("唤醒延迟已设置为 ") .. spin.value .. _(" 秒"), timeout = 2})
                end
            })
        end,
    })
end

-- Menu Helper: Utility Options
function BluetoothController:_addUtilityOptions(sub_items)
    -- Disconnect BLE
    table.insert(sub_items, {
        text = _("断开 BLE 连接"),
        callback = function()
            if BLEManager then
                BLEManager:disconnect()
                UIManager:show(InfoMessage:new{ text = _("已断开 BLE"), timeout = 2 })
            end
        end
    })

    -- Reload Input Devices
    table.insert(sub_items, {
        text = _("重新扫描输入设备"),
        callback = function()
            self:loadSettings()
            if self:reloadDevice() then
                UIManager:show(InfoMessage:new{ text = _("设备已重载"), timeout = 2 })
            else
                UIManager:show(InfoMessage:new{ text = _("重载失败"), timeout = 2 })
            end
        end
    })

    -- Clean up Dumps
    table.insert(sub_items, {
        text = _("清理蓝牙垃圾"),
        callback = function()
            local count = self:cleanupBluetoothDumps()
            UIManager:show(InfoMessage:new{ text = string.format(_("已清理 %d 个文件"), count), timeout = 2 })
        end
    })
end



function BluetoothController:onExit()
    if BLEManager then
        BLEManager:disconnect()
    end
    return true
end

return BluetoothController
