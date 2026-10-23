/* SPDX-License-Identifier: GPL-2.0-only */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include "win_device_identity.h"
#include "openvpn-msg.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { HANDLE pipe; int scenario; } server_ctx;

static DWORD WINAPI server(void *p)
{
    server_ctx *ctx = p;
    if (!ConnectNamedPipe(ctx->pipe, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) { return 4; }
    xy_identity_request_t req;
    DWORD got;
    if (!ReadFile(ctx->pipe, &req, sizeof(req), &got, NULL) || got != sizeof(req)) { return 1; }
    if (req.header.type != msg_xy_device_identity || req.version != XY_ID_PROTOCOL) { return 2; }
    xy_identity_response_t res = {0};
    res.header.type = msg_xy_device_identity_response;
    res.header.size = sizeof(res);
    res.header.message_id = req.header.message_id;
    res.version = XY_ID_PROTOCOL;
    strcpy(res.identity.uuid, "01234567-89AB-CDEF-0123-456789ABCDEF");
    strcpy(res.identity.serial, "OSDISK123");
    strcpy(res.identity.volume, "D:\\");
    strcpy(res.identity.model, "Test disk");
    res.identity.disk_number = 7;
    DWORD size = sizeof(res);
    switch (ctx->scenario)
    {
        case 1: res.version = 99; break;
        case 2: res.header.message_id++; break;
        case 3: res.header.type = msg_acknowledgement; size = sizeof(ack_message_t); break;
        case 4: memset(res.identity.serial, 'x', sizeof(res.identity.serial)); break;
        case 5: strcpy(res.identity.serial, "disk\nIV_INFO=bad"); break;
        case 6: res.error.code = ERROR_ACCESS_DENIED; strcpy(res.error.stage, "volume-open"); break;
        case 7: memset(res.error.stage, 'x', sizeof(res.error.stage)); res.error.code = ERROR_INVALID_DATA; break;
        case 8: memset(res.identity.model, 'x', sizeof(res.identity.model)); break;
        case 9: res.header.size--; break;
        case 10: strcpy(res.identity.uuid, "00000000-0000-0000-0000-000000000000"); break;
        case 11: Sleep(500); return 0; /* test binary uses a 100ms exchange deadline */
    }
    return WriteFile(ctx->pipe, &res, size, &got, NULL) && got == size ? 0 : 3;
}

int main(void)
{
    for (int scenario = 0; scenario <= 11; ++scenario)
    {
        WCHAR name[128];
        swprintf(name, 128, L"\\\\.\\pipe\\xy-device-test-%lu-%d", GetCurrentProcessId(), scenario);
        HANDLE pipe = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 4096, 4096, 0, NULL);
        if (pipe == INVALID_HANDLE_VALUE) { return 10; }
        HANDLE client = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (client == INVALID_HANDLE_VALUE) { return 11; }
        DWORD mode = PIPE_READMODE_MESSAGE;
        if (!SetNamedPipeHandleState(client, &mode, NULL, NULL)) { return 12; }
        server_ctx ctx = {pipe, scenario};
        HANDLE thread = CreateThread(NULL, 0, server, &ctx, 0, NULL);
        if (!thread) { return 13; }
        xy_hardware_identity id;
        xy_identity_error error;
        DWORD code = xy_get_hardware(client, &id, &error);
        bool valid = scenario == 0 ? code == 0 && strcmp(id.serial, "OSDISK123") == 0 && id.disk_number == 7 : code != 0;
        if (scenario == 6) { valid = code == ERROR_ACCESS_DENIED && strcmp(error.stage, "volume-open") == 0; }
        if (scenario == 11) { valid = code == ERROR_TIMEOUT; }
        CloseHandle(client);
        DWORD wait = WaitForSingleObject(thread, 3000), thread_result = 99;
        GetExitCodeThread(thread, &thread_result);
        CloseHandle(thread); CloseHandle(pipe);
        if (!valid || wait != WAIT_OBJECT_0 || thread_result != 0)
        { fprintf(stderr, "FAIL scenario=%d code=%lu worker=%lu wait=%lu\n", scenario, code, thread_result, wait); return 1; }
    }
    puts("PASS: 12 service protocol, malformed-response and timeout cases");
    return 0;
}
