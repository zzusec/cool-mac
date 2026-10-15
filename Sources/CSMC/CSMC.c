#include "CSMC.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <libproc.h>
#include <stdlib.h>
#include <IOKit/IOMessage.h>

uint32_t cm_power_will_sleep(void) { return kIOMessageSystemWillSleep; }
uint32_t cm_power_did_wake(void) { return kIOMessageSystemHasPoweredOn; }
uint32_t cm_power_can_sleep(void) { return kIOMessageCanSystemSleep; }

/* AppleSMC user-client ABI. Keep native alignment; do not pack. */
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCLimits;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCLimits limits;
    SMCInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMCMessage;
_Static_assert(sizeof(SMCMessage) == 80, "AppleSMC message ABI mismatch");
_Static_assert(offsetof(SMCMessage, bytes) == 48, "AppleSMC payload ABI mismatch");

uint32_t cm_fourcc(const char *s) {
    if (!s || strlen(s) != 4) return 0;
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint8_t)s[3];
}

static int call(uint32_t connection, SMCMessage *in, SMCMessage *out, char *error, size_t capacity) {
    memset(out, 0, sizeof(*out));
    size_t size = sizeof(*out);
    kern_return_t kr = IOConnectCallStructMethod(connection, 2, in, sizeof(*in), out, &size);
    if (kr != KERN_SUCCESS || size != sizeof(*out) || out->result != 0) {
        if (error && capacity) snprintf(error, capacity, "AppleSMC command %u failed: IOKit=0x%x, size=%zu, result=%u, status=%u", in->command, kr, size, out->result, out->status);
        return kr ? (int)kr : -1;
    }
    return 0;
}

int cm_smc_open(uint32_t *connection, char *error, size_t capacity) {
    if (!connection) return -1;
    *connection = 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) {
        if (error && capacity) snprintf(error, capacity, "AppleSMC service not found");
        return -1;
    }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    if (kr && error && capacity) snprintf(error, capacity, "IOServiceOpen AppleSMC failed: 0x%x", kr);
    return (int)kr;
}

void cm_smc_close(uint32_t connection) { if (connection) IOServiceClose(connection); }

static int metadata(uint32_t connection, const char *key, SMCMessage *out, char *error, size_t capacity) {
    SMCMessage in = {0};
    in.key = cm_fourcc(key);
    if (!in.key) return -1;
    in.command = 9;
    return call(connection, &in, out, error, capacity);
}

int cm_smc_read(uint32_t connection, const char *key, CMValue *value, char *error, size_t capacity) {
    SMCMessage info;
    if (!value || metadata(connection, key, &info, error, capacity)) return -1;
    if (info.info.size == 0 || info.info.size > 32) {
        if (error && capacity) snprintf(error, capacity, "SMC key %s unsupported size %u", key, info.info.size);
        return -1;
    }
    SMCMessage in = {0}, out;
    in.key = cm_fourcc(key);
    in.info.size = info.info.size;
    in.command = 5;
    if (call(connection, &in, &out, error, capacity)) return -1;
    memset(value, 0, sizeof(*value));
    value->type = info.info.type;
    value->size = info.info.size;
    value->attributes = info.info.attributes;
    memcpy(value->bytes, out.bytes, value->size);
    return 0;
}

int cm_smc_key_at(uint32_t connection, uint32_t index, char *key, char *error, size_t capacity) {
    SMCMessage in = {0}, out;
    in.command = 8;
    in.index = index;
    if (!key || call(connection, &in, &out, error, capacity)) return -1;
    key[0] = (char)(out.key >> 24); key[1] = (char)(out.key >> 16);
    key[2] = (char)(out.key >> 8); key[3] = (char)out.key; key[4] = 0;
    return 0;
}

int cm_smc_write_fan(uint32_t connection, const char *key, const CMValue *value, char *error, size_t capacity) {
    if (!key || strlen(key) != 4 || key[0] != 'F' || key[1] < '0' || key[1] > '9' ||
        !((key[2] == 'M' && key[3] == 'd') || (key[2] == 'T' && key[3] == 'g'))) {
        if (error && capacity) snprintf(error, capacity, "SMC write key is not in fan allowlist");
        return -1;
    }
    SMCMessage info;
    if (!value || metadata(connection, key, &info, error, capacity)) return -1;
    if (value->size > 32 || value->size != info.info.size || value->type != info.info.type) {
        if (error && capacity) snprintf(error, capacity, "SMC write metadata mismatch for %s", key);
        return -1;
    }
    double number;
    if (cm_decode_number(value, &number) || !isfinite(number) ||
        ((key[2] == 'M') && !(number == 0 || number == 1)) ||
        ((key[2] == 'T') && number != 0 && (number < 1000 || number > 10000))) {
        if (error && capacity) snprintf(error, capacity, "SMC fan value rejected");
        return -1;
    }
    if (key[2] == 'T' && number == 0) {
        char mode_key[] = {'F', key[1], 'M', 'd', 0};
        CMValue mode; double mode_number;
        if (cm_smc_read(connection, mode_key, &mode, error, capacity) ||
            cm_decode_number(&mode, &mode_number) || mode_number != 0) {
            if (error && capacity) snprintf(error, capacity, "Zero target allowed only after automatic mode is confirmed");
            return -1;
        }
    }
    SMCMessage in = {0}, out;
    in.key = cm_fourcc(key); in.command = 6; in.info.size = value->size;
    memcpy(in.bytes, value->bytes, value->size);
    return call(connection, &in, &out, error, capacity);
}

int cm_smc_clear_fan0_override(uint32_t connection, char *error, size_t capacity) {
    CMValue target, mode;
    if (cm_smc_read(connection, "F0Md", &mode, error, capacity) ||
        mode.type != cm_fourcc("ui8 ") || mode.size != 1 || mode.bytes[0] > 1 ||
        cm_smc_read(connection, "F0Tg", &target, error, capacity)) return -1;
    if (target.type != cm_fourcc("flt ") || target.size != 4) {
        if (error && capacity) snprintf(error, capacity, "Recovery requires the known Mac14,7 float target");
        return -1;
    }
    // Clearing the forced target is part of restoring automatic control, not a
    // user request for a stopped manual fan. The mode may still read as manual
    // until this clear has reached the controller; do not gate on that cache.
    SMCMessage in = {0}, out;
    in.key = cm_fourcc("F0Tg"); in.command = 6; in.info.size = 4;
    return call(connection, &in, &out, error, capacity);
}

int cm_decode_number(const CMValue *v, double *result) {
    if (!v || !result) return -1;
    const uint8_t *b = v->bytes;
    double n;
    if (v->type == cm_fourcc("flt ") && v->size == 4) {
        float f;
        memcpy(&f, b, sizeof(f));
        n = f;
    } else if (v->type == cm_fourcc("fpe2") && v->size == 2) {
        n = (((uint16_t)b[0] << 8) | b[1]) / 4.0;
    } else if (v->type == cm_fourcc("sp78") && v->size == 2) {
        n = (int16_t)(((uint16_t)b[0] << 8) | b[1]) / 256.0;
    } else if ((v->type == cm_fourcc("ui8 ") || v->type == cm_fourcc("flag")) && v->size == 1) {
        n = b[0];
    } else if (v->type == cm_fourcc("ui16") && v->size == 2) {
        n = ((uint16_t)b[0] << 8) | b[1];
    } else if (v->type == cm_fourcc("ui32") && v->size == 4) {
        n = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    } else return -1;
    if (!isfinite(n)) return -1;
    *result = n;
    return 0;
}

int cm_encode_number(const CMValue *meta, double number, CMValue *result) {
    if (!meta || !result || !isfinite(number)) return -1;
    *result = *meta;
    memset(result->bytes, 0, sizeof(result->bytes));
    if (meta->type == cm_fourcc("flt ") && meta->size == 4) {
        float f = (float)number;
        if (!isfinite(f)) return -1;
        memcpy(result->bytes, &f, sizeof(f));
    } else if (meta->type == cm_fourcc("fpe2") && meta->size == 2 && number >= 0 && number <= 16383.75) {
        uint16_t n = (uint16_t)llround(number * 4);
        result->bytes[0] = n >> 8; result->bytes[1] = n;
    } else if ((meta->type == cm_fourcc("ui8 ") || meta->type == cm_fourcc("flag")) && meta->size == 1 && number >= 0 && number <= 255 && trunc(number) == number) {
        result->bytes[0] = (uint8_t)number;
    } else return -1;
    return 0;
}

double cm_continuous_seconds(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return (double)mach_continuous_time() * (double)timebase.numer / (double)timebase.denom / 1e9;
}

int cm_conflicting_controller(char *name, size_t capacity) {
    int bytes = proc_listallpids(NULL, 0);
    if (bytes <= 0 || bytes > 1000000) return -1;
    size_t count = (size_t)bytes + 128;
    pid_t *pids = calloc(count, sizeof(pid_t));
    if (!pids) return -1;
    int used = proc_listallpids(pids, (int)(count * sizeof(pid_t)));
    if (used <= 0) { free(pids); return -1; }
    int found = 0;
    for (int i = 0; i < used && i < (int)count; ++i) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (!strcmp(base, "Macs Fan Control") || !strcmp(base, "Stats") ||
            !strcmp(base, "TG Pro") || !strcmp(base, "smcFanControl")) {
            if (name && capacity) snprintf(name, capacity, "%s", base);
            found = 1;
            break;
        }
    }
    free(pids);
    return found;
}
