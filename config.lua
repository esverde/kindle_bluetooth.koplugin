-- Global Plugin Configuration
-- 用于存储插件的全局状态，例如当前使用的协议模式

return {
    -- 当前协议模式: "classic" (普通蓝牙/RF) 或 "ble" (低功耗蓝牙)
    -- "classic": 使用 /dev/input/event* (默认)
    -- "ble": 使用 ble_service.lua 和 libkindlebt
    protocol = "ble"
}
