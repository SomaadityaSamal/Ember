#ifndef TELEMETRY_BRIDGE_H
#define TELEMETRY_BRIDGE_H
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    int32_t pid, parent_pid;
    uint32_t uid;
    uint64_t start_seconds, start_microseconds, cpu_nanoseconds, resident_bytes;
    char name[64];
    char path[4096];
} EmberProcess;
// Caller owns the result and releases it with ember_free_processes.
int ember_processes(EmberProcess **output, int *total);
void ember_free_processes(EmberProcess *processes);
// Revalidates ownership and process identity immediately before signaling.
int ember_signal(int32_t pid, uint64_t start_seconds, uint64_t start_microseconds, bool force);
uint32_t ember_smc_open(void);
void ember_smc_close(uint32_t connection);
bool ember_smc_read(uint32_t connection, const char *key, double *value);
// Narrow fan-control surface: firmware maximum or restoration of our own changes.
int ember_fans_max(uint32_t connection);
int ember_fans_restore(uint32_t connection);
bool ember_fans_verify_max(uint32_t connection);
const char *ember_embedded_client_requirement(void);

#endif
