#include "CSMC.h"
#include <stdio.h>
#include <string.h>

static void show(uint32_t connection, const char *key) {
    CMValue value;
    char error[256];
    if (cm_smc_read(connection, key, &value, error, sizeof(error))) {
        fprintf(stderr, "%s: %s\n", key, error);
        return;
    }
    char type[] = {value.type >> 24, value.type >> 16, value.type >> 8, value.type, 0};
    double n;
    if (cm_decode_number(&value, &n) == 0) printf("%s\t%s\t%u\t%.3f\n", key, type, value.size, n);
}

int main(int argc, char **argv) {
    uint32_t connection;
    char error[256];
    if (cm_smc_open(&connection, error, sizeof(error))) { fprintf(stderr, "%s\n", error); return 1; }
    const char *keys[] = {"FNum", "F0Md", "F0md", "Ftst", "F0Mn", "F0Mx", "F0Ac", "F0Tg"};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) show(connection, keys[i]);
    if (argc > 1 && !strcmp(argv[1], "--temperatures")) {
        CMValue value; double count;
        if (cm_smc_read(connection, "#KEY", &value, error, sizeof(error)) || cm_decode_number(&value, &count) || count < 0 || count > 20000) return 1;
        for (uint32_t i = 0; i < (uint32_t)count; ++i) {
            char key[5];
            if (cm_smc_key_at(connection, i, key, error, sizeof(error))) { fprintf(stderr, "%s\n", error); return 1; }
            if (key[0] == 'T') show(connection, key);
        }
    }
    cm_smc_close(connection);
    return 0;
}
