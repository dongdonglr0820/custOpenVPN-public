/* SPDX-License-Identifier: GPL-2.0-only */
#include "system_disk.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

extern bool xy_macos_store_from_info(CFDictionaryRef root, char store[128], char error[128]);
extern bool xy_macos_disk_serial(CFTypeRef value, char serial[256]);
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

static CFDictionaryRef
info(const char *xml)
{
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)xml, (CFIndex)strlen(xml));
    CFPropertyListRef result = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    return (CFDictionaryRef)result;
}

int
main(void)
{
    char store[128], error[128], serial[256];
    const char *cases[] = {
        "<dict><key>DeviceIdentifier</key><string>disk7s5s1</string>"
        "<key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk3s2</string></dict></array></dict>",
        "<dict><key>DeviceIdentifier</key><string>disk0s1</string></dict>",
        "<dict><key>APFSPhysicalStores</key><array>"
        "<dict><key>APFSPhysicalStore</key><string>disk0s2</string></dict>"
        "<dict><key>APFSPhysicalStore</key><string>disk1s2</string></dict></array></dict>",
        "<dict><key>APFSContainerReference</key><string>disk7</string></dict>",
        "<dict><key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk0;echo bad</string></dict></array></dict>",
        "<dict><key>APFSPhysicalStores</key><array></array></dict>",
    };
    for (unsigned int i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
    {
        CFDictionaryRef root = info(cases[i]);
        CHECK(root != NULL);
        bool ok = xy_macos_store_from_info(root, store, error);
        CFRelease(root);
        CHECK(ok == (i < 2));
        if (i == 0) { CHECK(!strcmp(store, "disk3s2")); }
        if (i == 1) { CHECK(!strcmp(store, "disk0s1")); }
    }
    CHECK(xy_disk_serial("  MAC_OS_DISK.123  ", serial));
    CHECK(!strcmp(serial, "MAC_OS_DISK.123"));
    CHECK(!xy_disk_serial("disk\nIV_DISK=other", serial));
    CHECK(!xy_disk_serial("00000000", serial));
    CHECK(!xy_disk_serial("unknown", serial));
    CHECK(xy_macos_disk_serial(CFSTR("  MAC_OS_DISK.123  "), serial));
    CHECK(!xy_macos_disk_serial(kCFBooleanTrue, serial));
    const UniChar nul_serial[] = { 'A', 'B', 0, 'C' };
    CFStringRef hidden_nul = CFStringCreateWithCharacters(NULL, nul_serial, 4);
    CHECK(hidden_nul != NULL);
    CHECK(!xy_macos_disk_serial(hidden_nul, serial));
    CFRelease(hidden_nul);
    puts("PASS: APFS snapshots, nonzero system disk, HFS, Fusion rejection, missing store, invalid names and serials");
    return 0;
}
