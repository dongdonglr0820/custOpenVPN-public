/* Read-only CI diagnostics for the actual OS disk's STORAGE_DEVICE_DESCRIPTOR. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <stddef.h>
#include <wchar.h>

int main(void)
{
    WCHAR windows[MAX_PATH], mount[MAX_PATH], volume[MAX_PATH], path[64];
    if (!GetSystemWindowsDirectoryW(windows, MAX_PATH)
        || !GetVolumePathNameW(windows, mount, MAX_PATH)
        || !GetVolumeNameForVolumeMountPointW(mount, volume, MAX_PATH)) { return 1; }
    wprintf(L"Windows=%ls mount=%ls volume=%ls\n", windows, mount, volume);
    volume[wcslen(volume)-1] = 0;
    HANDLE disk = CreateFileW(volume, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (disk == INVALID_HANDLE_VALUE) { printf("volume-open=%lu\n", GetLastError()); return 1; }
    unsigned char raw[65536] = {0};
    DWORD got = 0;
    BOOL ok = DeviceIoControl(disk, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, NULL, 0, raw, sizeof(raw), &got, NULL);
    CloseHandle(disk);
    if (!ok) { printf("extents=%lu\n", GetLastError()); return 1; }
    VOLUME_DISK_EXTENTS *ext = (VOLUME_DISK_EXTENTS *)raw;
    if (got < sizeof(*ext) || ext->NumberOfDiskExtents != 1) { printf("unsupported extents=%lu\n", ext->NumberOfDiskExtents); return 1; }
    swprintf(path, 64, L"\\\\.\\PhysicalDrive%lu", ext->Extents[0].DiskNumber);
    wprintf(L"selected=%ls\n", path);
    disk = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (disk == INVALID_HANDLE_VALUE) { return 1; }
    STORAGE_PROPERTY_QUERY query = {0};
    query.PropertyId = StorageDeviceProperty;
    query.QueryType = PropertyStandardQuery;
    ZeroMemory(raw, sizeof(raw));
    ok = DeviceIoControl(disk, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query), raw, sizeof(raw), &got, NULL);
    CloseHandle(disk);
    if (!ok || got < sizeof(STORAGE_DEVICE_DESCRIPTOR)) { printf("descriptor error=%lu bytes=%lu\n", GetLastError(), got); return 1; }
    STORAGE_DEVICE_DESCRIPTOR *desc = (STORAGE_DEVICE_DESCRIPTOR *)raw;
    printf("bytes=%lu Version=%lu Size=%lu sizeof=%zu raw-offset=%zu SerialNumberOffset=%lu ProductIdOffset=%lu\n",
           got, desc->Version, desc->Size, sizeof(*desc), offsetof(STORAGE_DEVICE_DESCRIPTOR, RawDeviceProperties), desc->SerialNumberOffset, desc->ProductIdOffset);
    if (desc->SerialNumberOffset && desc->SerialNumberOffset < got)
    {
        printf("serial bytes:");
        for (DWORD i = desc->SerialNumberOffset; i < got && i - desc->SerialNumberOffset < 160; ++i)
        { printf(" %02X", raw[i]); if (!raw[i]) { break; } }
        puts("");
    }
    else { puts("NO SERIAL NUMBER IN STORAGE DEVICE DESCRIPTOR"); }
    return 0;
}
