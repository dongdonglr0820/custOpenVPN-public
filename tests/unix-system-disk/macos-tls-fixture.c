/* SPDX-License-Identifier: GPL-2.0-only */
/* TEST ONLY. Never linked into, copied into, or packaged with the product.
 * The final core must reject the CI VM's missing/virtual disk first. A separate
 * test copy then uses this IOKit provider for real TLS serialization tests. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOMedia.h>
#include <stdbool.h>
#include <errno.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>

static CFTypeRef
fixture_property(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator,
                  IOOptionBits options)
{
    if (CFEqual(key, CFSTR("Serial Number")) && IOObjectConformsTo(entry, kIOMediaClass))
    {
        return CFRetain(CFSTR("CI-SYNTHETIC-MAC-SYSTEM-DISK"));
    }
    return IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}

static const void *
fixture_dictionary(CFDictionaryRef dictionary, const void *key)
{
    /* Stub the hardware-kind property itself, not string conversion used by
     * unrelated CoreFoundation code or plist serialization. */
    if (CFEqual(key, CFSTR("VirtualOrPhysical"))) { return CFSTR("Physical"); }
    return CFDictionaryGetValue(dictionary, key);
}

__attribute__((constructor)) static void
fixture_loaded(void)
{
    const char marker[] = "TEST_ONLY_DEVICE_PROVIDER_LOADED\n";
    (void)write(STDERR_FILENO, marker, sizeof(marker) - 1);
}

static int
fixture_execl(const char *path, const char *first, ...)
{
    char *argv[16];
    size_t count = 0;
    const char *next = first;
    va_list args;
    va_start(args, first);
    while (next && count < 15)
    {
        argv[count++] = (char *)next;
        next = va_arg(args, const char *);
    }
    va_end(args);
    if (next) { errno = E2BIG; return -1; }
    argv[count] = NULL;
    if (!strcmp(path, "/usr/sbin/diskutil"))
    {
        /* CI VMs can have SIP disabled. Never inject this provider into the
         * real diskutil child; only the temporary OpenVPN copy is under test. */
        char *clean_env[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", NULL };
        return execve(path, argv, clean_env);
    }
    return execv(path, argv);
}

#define XY_INTERPOSE(replacement_function, original_function) \
    __attribute__((used)) static struct \
    { const void *replacement; const void *original; } \
    interpose_##original_function __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(replacement_function), (const void *)(original_function) }

XY_INTERPOSE(fixture_property, IORegistryEntryCreateCFProperty);
XY_INTERPOSE(fixture_dictionary, CFDictionaryGetValue);
XY_INTERPOSE(fixture_execl, execl);
