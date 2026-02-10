#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
// Ensure kindlebt headers are available in include path
#include <kindlebt/kindlebt.h>

// Global pipe file descriptor for sending events to Lua
static int g_pipe_fd = -1;

// Event Header Structure (Packed for byte stream)
// [Type:1][Len:2][...Payload...]
typedef struct __attribute__((packed)) {
    uint8_t type;
    uint16_t len;
} event_header_t;

// Event Types
enum {
    EVENT_NOTIFY = 1,
    EVENT_CONNECT = 2,
    EVENT_DISCONNECT = 3
};

// --- Callback Implementations ---

void on_notify_cb(bleConnHandle conn_handle, bleGattCharacteristicsValue_t gatt_characteristics) {
    if (g_pipe_fd < 0) return;

    // In ACS headers, value is inside an anonymous union as blobValue
    if (!gatt_characteristics.blobValue.data) return;

    // Payload: [ConnHandle:size_t][DataLen:2][Data...]
    // We send: Header + ConnHandle + DataLen + Data

    // Calculate total size: handle + len + data
    uint16_t data_len = gatt_characteristics.blobValue.size;
    uint16_t payload_len = sizeof(bleConnHandle) + 2 + data_len;

    event_header_t header;
    header.type = EVENT_NOTIFY;
    header.len = payload_len;

    // Use a small buffer on stack or multiple writes
    uint8_t buf[512];
    if (sizeof(event_header_t) + payload_len > sizeof(buf)) {
        // Too large, just drop or handle specifically
        return;
    }

    uint8_t *ptr = buf;

    // Write Header
    memcpy(ptr, &header, sizeof(header));
    ptr += sizeof(header);

    // Write Payload
    memcpy(ptr, &conn_handle, sizeof(bleConnHandle));
    ptr += sizeof(bleConnHandle);

    memcpy(ptr, &data_len, 2);
    ptr += 2;

    memcpy(ptr, gatt_characteristics.blobValue.data, data_len);
    ptr += data_len;

    // Write to pipe
    write(g_pipe_fd, buf, ptr - buf);
}

// Note: on_connect_cb removed as GATT Client Callbacks in ACS headers
// don't include a generic "open" callback. Connection state is handled via GAP callbacks.

// --- Exported Functions ---

void adapter_set_pipe(int fd) {
    g_pipe_fd = fd;
}

// Fill the callback structure with our safe wrappers
void adapter_get_callbacks(bleGattClientCallbacks_t *callbacks) {
    if (!callbacks) return;

    // We assume the caller allocated the struct
    // Set our wrapper functions
    // ACS Header name: notify_characteristics_cb
    callbacks->notify_characteristics_cb = on_notify_cb;

    // Other callbacks like on_ble_gattc_open_cb do not exist in standard ACS GATT client struct
}
