/* SPDX-License-Identifier: GPL-2.0-only */
/* TEST ONLY. Never linked into, copied into, or packaged with the product.
 * The final core must reject the CI VM's missing/virtual disk first. A separate
 * test copy then uses this IOKit provider for real TLS serialization tests. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOMedia.h>
#include <stdbool.h>
#include <string.h>

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

static Boolean
fixture_string(CFStringRef value, char *buffer, CFIndex size, CFStringEncoding encoding)
{
    /* The VM has a virtual backing device. Only this non-shipping provider
     * substitutes its kind; APFS/root-to-whole-disk selection stays native. */
    if (CFEqual(value, CFSTR("Virtual")))
    {
        const char physical[] = "Physical";
        if (size < (CFIndex)sizeof(physical)) { return false; }
        memcpy(buffer, physical, sizeof(physical));
        return true;
    }
    return CFStringGetCString(value, buffer, size, encoding);
}

#define XY_INTERPOSE(replacement_function, original_function) \
    __attribute__((used)) static struct \
    { const void *replacement; const void *original; } \
    interpose_##original_function __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(replacement_function), (const void *)(original_function) }

XY_INTERPOSE(fixture_property, IORegistryEntryCreateCFProperty);
XY_INTERPOSE(fixture_string, CFStringGetCString);
