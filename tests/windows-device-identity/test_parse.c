/* SPDX-License-Identifier: GPL-2.0-only */
#include "device_identity_parse.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned int checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void)
{
    char out[128];
    CHECK(xy_identity_serial("  DISK_A.01_  ", 15, out, sizeof(out)));
    CHECK(strcmp(out, "DISK_A.01_") == 0);
    const char *bad[] = { "", "  ", "UNKNOWN", "To be filled by O.E.M.", "0000_0000.",
                          "ffff-FFFF", "---", "disk\nIV_USER=other", "disk\r", "disk\t" };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
    { CHECK(!xy_identity_serial(bad[i], strlen(bad[i]) + 1, out, sizeof(out))); }
    CHECK(!xy_identity_text("abcdef", 3, out, sizeof(out)));
    CHECK(!xy_identity_text("abcd", 5, out, 4));
    CHECK(xy_identity_text("machine\\user", 13, out, sizeof(out)));
    CHECK(xy_identity_reserved_env("IV_DISK=x"));
    CHECK(xy_identity_reserved_env("UV_DEVICE_ID_SCHEMA=x"));
    CHECK(!xy_identity_reserved_env("IV_DISK_OTHER=x"));
    CHECK(!xy_identity_reserved_env("IV_DISK"));

    unsigned char descriptor[128] = {0};
    memcpy(descriptor + 40, "SYSTEM-DISK-123", 16);
    CHECK(xy_identity_descriptor(descriptor, sizeof(descriptor), 40, 36, out, sizeof(out)));
    CHECK(strcmp(out, "SYSTEM-DISK-123") == 0);
    CHECK(!xy_identity_descriptor(descriptor, 128, 0, 36, out, sizeof(out)));
    CHECK(!xy_identity_descriptor(descriptor, 128, 129, 36, out, sizeof(out)));
    CHECK(!xy_identity_descriptor(descriptor, 45, 40, 36, out, sizeof(out)));
    CHECK(!xy_identity_descriptor(descriptor, 128, 40, 36, out, 4));

    uint32_t first_boot[] = {0,0}, next_boot[] = {3,3,3}, spanning[] = {3,1};
    uint32_t disk = 999;
    CHECK(xy_identity_disk(first_boot, 2, &disk) && disk == 0);
    CHECK(xy_identity_disk(next_boot, 3, &disk) && disk == 3);
    CHECK(!xy_identity_disk(spanning, 2, &disk));
    CHECK(!xy_identity_disk(next_boot, 0, &disk));
    /* Reorder the disk table but resolve by the OS-volume's current disk number. */
    const char *boot1[] = {"SYSTEM123", "DATA456", "USB789", "OTHER012"};
    const char *boot2[] = {"USB789", "OTHER012", "DATA456", "SYSTEM123"};
    uint32_t a, b;
    CHECK(xy_identity_disk(first_boot, 2, &a) && xy_identity_disk(next_boot, 3, &b));
    CHECK(strcmp(boot1[a], boot2[b]) == 0);

    unsigned char smbios[34] = {0};
    smbios[1] = 3; smbios[2] = 2; smbios[4] = 26;
    smbios[8] = 1; smbios[9] = 24;
    for (unsigned char i = 0; i < 16; ++i) { smbios[16 + i] = i; }
    char uuid[37];
    CHECK(xy_identity_smbios(smbios, sizeof(smbios), uuid));
    CHECK(strcmp(uuid, "03020100-0504-0706-0809-0A0B0C0D0E0F") == 0);
    smbios[1] = 2; smbios[2] = 5;
    CHECK(xy_identity_smbios(smbios, sizeof(smbios), uuid));
    CHECK(strcmp(uuid, "00010203-0405-0607-0809-0A0B0C0D0E0F") == 0);
    CHECK(!xy_identity_smbios(smbios, 20, uuid));
    smbios[9] = 3;
    CHECK(!xy_identity_smbios(smbios, sizeof(smbios), uuid));
    smbios[9] = 24; smbios[33] = 1;
    CHECK(!xy_identity_smbios(smbios, sizeof(smbios), uuid));
    smbios[33] = 0;
    memset(smbios + 16, 0, 16);
    CHECK(!xy_identity_smbios(smbios, sizeof(smbios), uuid));
    memset(smbios + 16, 255, 16);
    CHECK(!xy_identity_smbios(smbios, sizeof(smbios), uuid));

    /* Deterministic malformed-buffer sweep; run under ASan/UBSan locally. */
    unsigned char fuzz[512];
    uint32_t seed = 42;
    for (size_t n = 0; n < 10000; ++n)
    {
        for (size_t i = 0; i < sizeof(fuzz); ++i)
        { seed = seed * 1664525U + 1013904223U; fuzz[i] = (unsigned char)(seed >> 24); }
        (void)xy_identity_smbios(fuzz, n % sizeof(fuzz), uuid);
        (void)xy_identity_descriptor(fuzz, n % sizeof(fuzz), seed % 550U, 36, out, sizeof(out));
    }
    printf("PASS: %u assertions and 10000 malformed-buffer cases\n", checks);
    return 0;
}
