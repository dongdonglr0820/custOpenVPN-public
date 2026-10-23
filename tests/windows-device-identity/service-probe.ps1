# Exercise the installed interactive service's actual launch/IPC path.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = 'Stop'
$pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'openvpn\service',
    [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
try {
    $pipe.Connect(10000)
    $pipe.ReadMode = [IO.Pipes.PipeTransmissionMode]::Message
    $options = '--show-device-info --log "' + "$Work\$Name.log" + '"'
    $data = [Text.Encoding]::Unicode.GetBytes("$Work`0$options`0`0")
    $pipe.Write($data, 0, $data.Length)
    $buffer = New-Object byte[] 4096
    $pending = $pipe.ReadAsync($buffer, 0, $buffer.Length)
    if (-not $pending.Wait(10000)) { throw 'Service launch timed out' }
    $reply = [Text.Encoding]::Unicode.GetString($buffer, 0, $pending.Result)
    if (-not $reply.StartsWith("0x00000000`n")) { throw "Service launch failed: $reply" }
    $deadline = (Get-Date).AddSeconds(25)
    do {
        if (Test-Path "$Work\$Name.log") {
            $log = Get-Content -Raw "$Work\$Name.log"
            if ($log -match '(?m)^IV_DISK=.+$') {
                if ($log -notmatch '(?m)^via=interactive-service\r?$') { throw 'Collector bypassed service' }
                return
            }
            if ($log -match 'DEVICE_IDENTITY_ERROR') { throw $log }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw 'Service diagnostic did not complete'
} finally { $pipe.Dispose() }
