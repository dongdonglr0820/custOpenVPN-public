/* Test-only launch harness. Never packaged in the MSI. Supplies synthetic hardware
 * through an inherited service pipe to test the installed core's real TLS serializer
 * on CI hosts whose OS disk has no serial. User identity is still collected natively. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include "openvpn-msg.h"
#include <stdio.h>
#include <wchar.h>
#include <string.h>

static DWORD WINAPI respond(void *arg)
{
    HANDLE pipe = arg;
    if (!ConnectNamedPipe(pipe, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) { return 1; }
    xy_identity_request_t req;
    DWORD got;
    if (!ReadFile(pipe, &req, sizeof(req), &got, NULL) || got != sizeof(req)
        || req.header.type != msg_xy_device_identity || req.version != XY_ID_PROTOCOL) { return 2; }
    xy_identity_response_t res = {0};
    res.header.type = msg_xy_device_identity_response;
    res.header.size = sizeof(res);
    res.header.message_id = req.header.message_id;
    res.version = XY_ID_PROTOCOL;
    strcpy(res.identity.uuid, "01234567-89AB-CDEF-0123-456789ABCDEF");
    strcpy(res.identity.serial, "CI-FIXTURE-SYSTEM-DISK");
    strcpy(res.identity.model, "Synthetic test fixture");
    strcpy(res.identity.volume, "C:\\");
    return WriteFile(pipe, &res, sizeof(res), &got, NULL) && got == sizeof(res) ? 0 : 3;
}

int wmain(int argc, WCHAR **argv)
{
    if (argc != 2) { return 10; }
    WCHAR name[128], command[256];
    swprintf(name, 128, L"\\\\.\\pipe\\xy-tls-fixture-%lu", GetCurrentProcessId());
    HANDLE pipe = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 4096, 4096, 0, NULL);
    if (pipe == INVALID_HANDLE_VALUE) { return 11; }
    SECURITY_ATTRIBUTES inherit = {sizeof(inherit), NULL, TRUE};
    HANDLE client = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, &inherit, OPEN_EXISTING, 0, NULL);
    if (client == INVALID_HANDLE_VALUE) { CloseHandle(pipe); return 12; }
    DWORD mode = PIPE_READMODE_MESSAGE;
    if (!SetNamedPipeHandleState(client, &mode, NULL, NULL)) { return 13; }
    swprintf(command, 256, L"openvpn --config client.ovpn --writepid fixture-client.pid --msg-channel %llu",
             (unsigned long long)(uintptr_t)client);
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION child = {0};
    if (!CreateProcessW(argv[1], command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &startup, &child))
    { CloseHandle(client); CloseHandle(pipe); return 14; }
    CloseHandle(client);
    HANDLE worker = CreateThread(NULL, 0, respond, pipe, 0, NULL);
    if (!worker) { TerminateProcess(child.hProcess, 1); return 15; }
    if (WaitForSingleObject(child.hProcess, 45000) != WAIT_OBJECT_0)
    { TerminateProcess(child.hProcess, 1); WaitForSingleObject(child.hProcess, 5000); }
    CancelSynchronousIo(worker);
    if (WaitForSingleObject(worker, 5000) != WAIT_OBJECT_0) { return 16; }
    DWORD result = 99;
    GetExitCodeThread(worker, &result);
    CloseHandle(worker); CloseHandle(pipe);
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
    return result == 0 ? 0 : 17;
}
