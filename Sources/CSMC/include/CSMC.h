#ifndef COOLMAC_SMC_H
#define COOLMAC_SMC_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t type;
    uint32_t size;
    uint8_t attributes;
    uint8_t bytes[32];
} CMValue;

int cm_smc_open(uint32_t *connection, char *error, size_t capacity);
void cm_smc_close(uint32_t connection);
int cm_smc_read(uint32_t connection, const char *key, CMValue *value, char *error, size_t capacity);
int cm_smc_key_at(uint32_t connection, uint32_t index, char *key, char *error, size_t capacity);
/* Only F[0-9]Md and F[0-9]Tg on the commissioned Apple Silicon profile. */
int cm_smc_write_fan(uint32_t connection, const char *key, const CMValue *value, char *error, size_t capacity);
/* Fixed recovery-only operation; caller validates ownership, then confirms mode. */
int cm_smc_clear_fan0_override(uint32_t connection, char *error, size_t capacity);
uint32_t cm_fourcc(const char *text);
int cm_decode_number(const CMValue *value, double *result);
int cm_encode_number(const CMValue *metadata, double number, CMValue *result);
double cm_continuous_seconds(void);
int cm_conflicting_controller(char *name, size_t capacity);
uint32_t cm_power_will_sleep(void);
uint32_t cm_power_did_wake(void);
uint32_t cm_power_can_sleep(void);

#ifdef __cplusplus
}
#endif
#endif
