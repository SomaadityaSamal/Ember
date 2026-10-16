#include "TelemetryBridge.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>

int ember_processes(EmberProcess **output, int *total) {
    *output = NULL;
    int capacity = proc_listallpids(NULL, 0) + 512;
    if (capacity <= 512) { *total = 0; return 0; }
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    EmberProcess *rows = calloc((size_t)capacity, sizeof(EmberProcess));
    if (!pids || !rows) { free(pids); free(rows); *total = 0; return 0; }
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    *total = count > 0 ? count : 0;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    int used = 0;
    for (int i = 0; i < count && i < capacity; i++) {
        if (pids[i] <= 0) continue;
        struct proc_taskallinfo info = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTASKALLINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        EmberProcess *row = &rows[used++];
        row->pid = pids[i]; row->parent_pid = info.pbsd.pbi_ppid; row->uid = info.pbsd.pbi_uid;
        row->start_seconds = info.pbsd.pbi_start_tvsec;
        row->start_microseconds = info.pbsd.pbi_start_tvusec;
        // proc_taskinfo CPU counters use Mach absolute ticks, not nanoseconds.
        // On Apple Silicon one tick is commonly ~41.67ns; Intel often uses 1ns.
        uint64_t ticks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system;
        row->cpu_nanoseconds = (uint64_t)(((__uint128_t)ticks * timebase.numer) / timebase.denom);
        row->resident_bytes = info.ptinfo.pti_resident_size;
        strlcpy(row->name, info.pbsd.pbi_name[0] ? info.pbsd.pbi_name : info.pbsd.pbi_comm, sizeof(row->name));
        proc_pidpath(pids[i], row->path, sizeof(row->path));
    }
    free(pids); *output = rows; return used;
}
void ember_free_processes(EmberProcess *p) { free(p); }

int ember_signal(int32_t pid, uint64_t seconds, uint64_t micros, bool force) {
    if (pid <= 1 || pid == getpid()) return EPERM;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return ESRCH;
    if (info.pbi_start_tvsec != seconds || info.pbi_start_tvusec != micros) return ESRCH;
    if (info.pbi_uid != getuid() || (info.pbi_flags & PROC_FLAG_SYSTEM)) return EPERM;
    char path[4096] = {0}; proc_pidpath(pid, path, sizeof(path));
    // System services and the login session must never be terminated by this UI.
    if (!path[0] || strncmp(path, "/System/Library/", 16) == 0 ||
        strncmp(path, "/usr/libexec/", 13) == 0 || strncmp(path, "/sbin/", 6) == 0) return EPERM;
    return kill(pid, force ? SIGKILL : SIGTERM) == 0 ? 0 : errno;
}

// AppleSMC user-client ABI. Monitoring uses key-info and read commands.
// The bounded fan-write routines below are invoked only by the root helper.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVersion version; SMCPLimit limit; SMCKeyInfo info;
    uint8_t result, status, command; uint32_t data; uint8_t bytes[32];
} SMCRequest;
_Static_assert(sizeof(SMCRequest) == 80, "AppleSMC ABI must be 80 bytes");
static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint8_t)s[3];
}
uint32_t ember_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : 0;
}
void ember_smc_close(uint32_t c) { if (c) IOServiceClose(c); }
bool ember_smc_read(uint32_t c, const char *key, double *value) {
    if (!c || !key || strlen(key) != 4) return false;
    SMCRequest in = {0}, out = {0}; size_t size = sizeof(out);
    in.key = fourcc(key); in.command = 9; // key metadata
    if (IOConnectCallStructMethod(c, 2, &in, sizeof(in), &out, &size) != KERN_SUCCESS || out.result || out.info.size > 32 || !out.info.size) return false;
    in.info = out.info; in.command = 5; // read bytes
    memset(&out, 0, sizeof(out)); size = sizeof(out);
    if (IOConnectCallStructMethod(c, 2, &in, sizeof(in), &out, &size) != KERN_SUCCESS || out.result) return false;
    uint8_t *b = out.bytes; double result;
    if (in.info.type == fourcc("flt ") && in.info.size == 4) {
        float f; memcpy(&f, b, sizeof(f)); result = f;
    } else if (in.info.type == fourcc("sp78") && in.info.size == 2) {
        result = (int16_t)((b[0] << 8) | b[1]) / 256.0;
    } else if (in.info.type == fourcc("fpe2") && in.info.size == 2) {
        result = ((b[0] << 8) | b[1]) / 4.0;
    } else if (in.info.type == fourcc("ui8 ") && in.info.size == 1) {
        result = b[0];
    } else if (in.info.type == fourcc("ui16") && in.info.size == 2) {
        result = (b[0] << 8) | b[1];
    } else if (in.info.type == fourcc("ui32") && in.info.size == 4) {
        result = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    } else return false;
    if (!isfinite(result)) return false;
    *value = result; return true;
}

// These routines are used only by the separately authorized fan helper.
// There is deliberately no API for arbitrary keys or user-specified RPM values.
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
const char *ember_embedded_client_requirement(void) {
    unsigned long size = 0;
    const uint8_t *bytes = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(0), "__TEXT", "__ember_client", &size);
    if (!bytes || size == 0 || bytes[size - 1] != 0) return NULL;
    return (const char *)bytes;
}
static int fan_write_error = 0;
static bool fan_write(uint32_t c, const char *key, double value) {
    // Internal allowlist. Never expose a general SMC write RPC.
    bool allowed = strcmp(key, "Ftst") == 0 || strcmp(key, "FS! ") == 0 ||
        (strlen(key) == 4 && key[0] == 'F' && key[1] >= '0' && key[1] <= '9' &&
         (strcmp(key + 2, "Md") == 0 || strcmp(key + 2, "md") == 0 || strcmp(key + 2, "Tg") == 0));
    if (!allowed || !isfinite(value) || value < 0 || value > 30000) return false;
    SMCRequest in = {0}, out = {0}; size_t size = sizeof(out);
    in.key = fourcc(key); in.command = 9;
    if (IOConnectCallStructMethod(c, 2, &in, sizeof(in), &out, &size) != KERN_SUCCESS || out.result || !out.info.size || out.info.size > 32) return false;
    in.info = out.info; in.command = 6;
    if (in.info.type == fourcc("flt ") && in.info.size == 4) {
        float f = (float)value; memcpy(in.bytes, &f, 4);
    } else if (in.info.type == fourcc("fpe2") && in.info.size == 2 && value <= 16383) {
        uint16_t v = (uint16_t)round(value * 4); in.bytes[0] = v >> 8; in.bytes[1] = v & 255;
    } else if (in.info.type == fourcc("ui8 ") && in.info.size == 1 && value <= 255) {
        in.bytes[0] = (uint8_t)value;
    } else if (in.info.type == fourcc("ui16") && in.info.size == 2) {
        uint16_t v = (uint16_t)value; in.bytes[0] = v >> 8; in.bytes[1] = v & 255;
    } else return false;
    memset(&out, 0, sizeof(out)); size = sizeof(out);
    // Write requests carry only the payload length. Metadata type/attributes are
    // read replies and must not be echoed into the firmware write request.
    in.info.type = 0; in.info.attributes = 0;
    kern_return_t result = IOConnectCallStructMethod(c, 2, &in, sizeof(in), &out, &size);
    if (result != KERN_SUCCESS) { fan_write_error = (int)result; return false; }
    if (out.result) { fan_write_error = 0x10000 | out.result; return false; }
    fan_write_error = 0;
    return true;
}
static uint16_t owned_fans = 0;
static bool owns_test_flag = false;
static bool fan_mode_key(uint32_t c, int fan, char key[5], double *mode) {
    snprintf(key, 5, "F%dMd", fan);
    if (ember_smc_read(c, key, mode)) return true;
    snprintf(key, 5, "F%dmd", fan);
    return ember_smc_read(c, key, mode);
}
int ember_fans_restore(uint32_t c) {
    double bits = 0;
    bool legacy = ember_smc_read(c, "FS! ", &bits);
    for (int i = 0; i < 10; i++) {
        if (!(owned_fans & (1 << i))) continue;
        char key[5]; double mode;
        if (fan_mode_key(c, i, key, &mode)) fan_write(c, key, 0);
        else if (legacy) {
            bits = (uint16_t)bits & ~(1 << i);
            fan_write(c, "FS! ", bits);
        }
    }
    if (owns_test_flag) fan_write(c, "Ftst", 0);
    // Restoration is asynchronous too. Confirm firmware state after releasing
    // the diagnostic flag before reporting an error or dropping ownership.
    for (int attempt = 0; attempt < 30; attempt++) {
        if (owns_test_flag) {
            double test;
            if (ember_smc_read(c, "Ftst", &test) && test == 0) owns_test_flag = false;
        }
        for (int i = 0; i < 10; i++) {
            if (!(owned_fans & (1 << i))) continue;
            char key[5]; double observed;
            bool restored = fan_mode_key(c, i, key, &observed) ? observed == 0 || observed == 3 :
                (ember_smc_read(c, "FS! ", &observed) && !((uint16_t)observed & (1 << i)));
            if (restored && !owns_test_flag) owned_fans &= ~(1 << i);
        }
        if (!owned_fans && !owns_test_flag) return 0;
        usleep(100000);
    }
    return EIO;
}
int ember_fans_max(uint32_t c) {
    fan_write_error = 0;
    if (geteuid() != 0) return EPERM;
    double number;
    if (!ember_smc_read(c, "FNum", &number) || number < 1 || number > 10) return ENODEV;
    int count = (int)number;
    double max[10] = {0};
    double test = 0, bits = 0;
    bool legacy = ember_smc_read(c, "FS! ", &bits);
    if (!owned_fans && ((ember_smc_read(c, "Ftst", &test) && test != 0) || (legacy && bits != 0))) return EBUSY;
    // Preflight every fan before making any change.
    for (int i = 0; i < count; i++) {
        char key[5], modekey[5]; double mode = 0;
        snprintf(key, 5, "F%dMx", i);
        if (!ember_smc_read(c, key, &max[i]) || max[i] < 500 || max[i] > 30000) return ENOTSUP;
        if (fan_mode_key(c, i, modekey, &mode)) {
            if (!(owned_fans & (1 << i)) && mode == 1) return EBUSY;
        } else if (!legacy) return ENOTSUP;
    }
    // A successful SMC write can precede the actual firmware transition. Confirm
    // mode and target over several samples; never equate transport success to ownership.
    uint16_t requested = (uint16_t)((1u << count) - 1);
    owned_fans |= requested;
    bool unlocked = owns_test_flag;
    int stable = 0;
    for (int attempt = 0; attempt < 100; attempt++) {
        for (int i = 0; i < count; i++) {
            char key[5], modekey[5]; double mode = 0;
            bool modern = fan_mode_key(c, i, modekey, &mode);
            bool manual = false;
            if (modern) {
                if (mode != 1) fan_write(c, modekey, 1);
                manual = fan_mode_key(c, i, modekey, &mode) && mode == 1;
            } else {
                bits = (uint16_t)bits | (1 << i);
                fan_write(c, "FS! ", bits);
                double observed = 0;
                manual = ember_smc_read(c, "FS! ", &observed) && ((uint16_t)observed & (1 << i));
            }
            // Firmware may acknowledge a mode write before applying it. Leave
            // its automatic target untouched until manual mode is read back.
            if (!manual) continue;
            snprintf(key, 5, "F%dTg", i);
            if (!fan_write(c, key, max[i])) {
                int error = fan_write_error ? fan_write_error : EIO;
                ember_fans_restore(c); return error;
            }
        }
        if (ember_fans_verify_max(c)) {
            if (++stable >= 3) return 0;
        } else {
            stable = 0;
            if (!unlocked && ember_smc_read(c, "Ftst", &test)) {
                if (fan_write(c, "Ftst", 1)) {
                    owns_test_flag = true; unlocked = true;
                    // Give thermalmonitord time to yield before retrying manual mode.
                    usleep(3000000);
                } else {
                    int error = fan_write_error ? fan_write_error : EIO;
                    ember_fans_restore(c); return error;
                }
            }
        }
        usleep(100000);
    }
    int error = fan_write_error ? fan_write_error : ETIMEDOUT;
    ember_fans_restore(c);
    return error;
}

bool ember_fans_verify_max(uint32_t c) {
    if (!owned_fans) return false;
    for (int i = 0; i < 10; i++) {
        if (!(owned_fans & (1 << i))) continue;
        char key[5]; double target, maximum, mode, bits;
        if (fan_mode_key(c, i, key, &mode)) { if (mode != 1) return false; }
        else if (!ember_smc_read(c, "FS! ", &bits) || !((uint16_t)bits & (1 << i))) return false;
        snprintf(key, 5, "F%dTg", i); if (!ember_smc_read(c, key, &target)) return false;
        snprintf(key, 5, "F%dMx", i); if (!ember_smc_read(c, key, &maximum) || target < maximum - 1) return false;
    }
    return true;
}
