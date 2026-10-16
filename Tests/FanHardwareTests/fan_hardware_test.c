// Deterministic SMC simulator. This executable never opens or changes hardware.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
static uid_t simulated_uid = 0;
static uid_t fake_geteuid(void) { return simulated_uid; }
static int fake_usleep(useconds_t delay) { (void)delay; return 0; }
static kern_return_t fake_call(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
#define geteuid fake_geteuid
#define usleep fake_usleep
#define IOConnectCallStructMethod fake_call
#include "../../Sources/TelemetryBridge/TelemetryBridge.c"
#undef IOConnectCallStructMethod
#undef geteuid
#undef usleep

static double current_mode, test_flag, target, maximum, fan_count;
static bool target_fails, restoration_fails, unlock_fails;
static int writes, manual_requests;
static bool delayed_mode;
static bool delayed_restore, restore_pending;
static int restore_reads;
static kern_return_t fake_call(mach_port_t connection, uint32_t selector, const void *input, size_t input_size, void *output, size_t *output_size) {
    (void)connection;
    assert(selector == 2 && input_size == sizeof(SMCRequest) && *output_size == sizeof(SMCRequest));
    const SMCRequest *in = input;
    SMCRequest *out = output;
    memset(out, 0, sizeof(*out));
    char key[5] = {(char)(in->key >> 24), (char)(in->key >> 16), (char)(in->key >> 8), (char)in->key, 0};
    double *value = NULL;
    bool floating = false;
    if (strcmp(key, "FNum") == 0) value = &fan_count;
    if (strcmp(key, "F0Md") == 0) value = &current_mode;
    if (strcmp(key, "Ftst") == 0) value = &test_flag;
    if (strcmp(key, "F0Mx") == 0) { value = &maximum; floating = true; }
    if (strcmp(key, "F0Tg") == 0) { value = &target; floating = true; }
    if (!value) { out->result = 0x84; return KERN_SUCCESS; }
    if (in->command == 9) {
        out->info.size = floating ? 4 : 1;
        out->info.type = fourcc(floating ? "flt " : "ui8 ");
        out->info.attributes = 0xD0;
    } else if (in->command == 5) {
        if (value == &current_mode && restore_pending && ++restore_reads >= 3) {
            current_mode = 3; restore_pending = false;
        }
        if (floating) { float f = (float)*value; memcpy(out->bytes, &f, 4); }
        else out->bytes[0] = (uint8_t)*value;
    } else if (in->command == 6) {
        writes++;
        assert(in->info.type == 0 && in->info.attributes == 0);
        double desired;
        if (floating) { float f; memcpy(&f, in->bytes, 4); desired = f; }
        else desired = in->bytes[0];
        if (restoration_fails && desired == 0 && (value == &current_mode || value == &test_flag)) { out->result = 0x82; return KERN_SUCCESS; }
        if (value == &current_mode && desired == 1 && current_mode == 3 && test_flag == 0) { out->result = 0x82; return KERN_SUCCESS; }
        if (value == &test_flag && desired == 1 && unlock_fails) { out->result = 0x82; return KERN_SUCCESS; }
        if (value == &target && target_fails) { out->result = 0x87; return KERN_SUCCESS; }
        if (value == &current_mode && desired == 1 && delayed_mode && ++manual_requests < 4) {
            current_mode = 0; return KERN_SUCCESS; // Accepted but not yet applied.
        }
        if (delayed_restore && desired == 0 && (value == &current_mode || value == &test_flag)) {
            restore_pending = true;
            if (value == &test_flag) test_flag = 0;
            return KERN_SUCCESS;
        }
        *value = desired;
        if (value == &test_flag && desired == 0) current_mode = 3;
    } else assert(!"Unexpected SMC command");
    return KERN_SUCCESS;
}
static void reset(void) {
    current_mode = 3; test_flag = 0; target = 0; maximum = 6550; fan_count = 1;
    target_fails = false; restoration_fails = false; unlock_fails = false; writes = 0;
    owned_fans = 0; owns_test_flag = false; simulated_uid = 0; manual_requests = 0; delayed_mode = false;
    delayed_restore = false; restore_pending = false; restore_reads = 0;
}
int main(void) {
    reset();
    assert(ember_fans_max(1) == 0);
    assert(target == maximum && current_mode == 1 && test_flag == 1);
    assert(ember_fans_verify_max(1));
    assert(ember_fans_restore(1) == 0);
    assert(current_mode == 3 && test_flag == 0 && owned_fans == 0);

    reset(); delayed_mode = true;
    assert(ember_fans_max(1) == 0 && manual_requests >= 4);
    assert(ember_fans_verify_max(1));
    assert(ember_fans_restore(1) == 0);

    reset(); assert(ember_fans_max(1) == 0); delayed_restore = true;
    assert(ember_fans_restore(1) == 0 && restore_reads >= 3);
    assert(current_mode == 3 && test_flag == 0 && owned_fans == 0);

    reset(); target_fails = true;
    assert(ember_fans_max(1) != 0);
    assert(current_mode == 3 && test_flag == 0 && owned_fans == 0);

    reset(); current_mode = 1;
    assert(ember_fans_max(1) == EBUSY && writes == 0);
    reset(); test_flag = 1;
    assert(ember_fans_max(1) == EBUSY && writes == 0);
    reset(); maximum = 0;
    assert(ember_fans_max(1) == ENOTSUP && writes == 0);
    reset(); fan_count = 0;
    assert(ember_fans_max(1) == ENODEV && writes == 0);
    reset(); simulated_uid = 501;
    assert(ember_fans_max(1) == EPERM && writes == 0);
    reset(); unlock_fails = true;
    assert(ember_fans_max(1) != 0 && target == 0 && test_flag == 0);

    reset(); assert(ember_fans_max(1) == 0); restoration_fails = true;
    assert(ember_fans_restore(1) != 0 && owned_fans != 0);
    restoration_fails = false;
    assert(ember_fans_restore(1) == 0 && owned_fans == 0 && test_flag == 0);

    reset();
    assert(!fan_write(1, "BAD!", 1) && writes == 0);
    assert(!fan_write(1, "F0Tg", -1) && writes == 0);
    assert(!fan_write(1, "F0Tg", NAN) && writes == 0);
    puts("PASS: simulated fan acquisition, maximum verification, restoration, partial failures, ownership, input bounds and root checks.");
    return 0;
}
