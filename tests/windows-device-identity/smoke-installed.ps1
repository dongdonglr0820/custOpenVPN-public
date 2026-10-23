# Only run on an ephemeral CI Windows runner: installs the MSI and creates a temporary local user.
param([Parameter(Mandatory)][string]$Msi, [Parameter(Mandatory)][string]$Work,
      [Parameter(Mandatory)][string]$StorageProbe, [Parameter(Mandatory)][string]$TlsFixture)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
New-Item -ItemType Directory -Force $Work | Out-Null
$install = Start-Process msiexec.exe -ArgumentList @('/i', "`"$Msi`"", '/qn', '/norestart', '/L*v', "`"$Work\install.log`"") -PassThru -Wait
if ($install.ExitCode -notin @(0, 3010)) { throw "MSI install failed: $($install.ExitCode)" }
$bin = "$env:ProgramFiles\OpenVPN\bin\openvpn.exe"
if (-not (Test-Path $bin)) { throw 'Installed core missing' }
$version = (& $bin --version) -join "`n"
$expectedVersion = "$($env:OPENVPN_REF.TrimStart('v'))-$env:XY_VERSION-$env:XY_DATE"
if ($version -notmatch [regex]::Escape("OpenVPN $expectedVersion ")) { throw "Unexpected core version: $version" }
$version | Set-Content "$Work\version.log"

function Read-Identity([string]$Path) {
    $values = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^(IV_[A-Z]+|schema|via|disk_number|windows_volume)=(.*)$') {
            if ($values.ContainsKey($Matches[1])) { throw "Duplicate identity field in $Path" }
            $values[$Matches[1]] = $Matches[2]
        }
    }
    foreach ($key in @('IV_PLAT', 'IV_USER', 'IV_INFO', 'IV_DISK', 'schema', 'via', 'disk_number', 'windows_volume')) {
        if (-not $values[$key]) { throw "Missing $key in $Path" }
    }
    if ($values.schema -ne 'win-system-disk-v1' -or $values.IV_PLAT -ne 'win') { throw 'Wrong schema/platform' }
    return $values
}
function Assert-SameHardware($First, $Second) {
    foreach ($key in @('IV_INFO', 'IV_DISK', 'disk_number', 'windows_volume')) {
        if ($First[$key] -cne $Second[$key]) { throw "Hardware differs: $key" }
    }
}
$driveLetter = [IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')).Substring(0, 1)
$osDisk = Get-Partition -DriveLetter $driveLetter | Get-Disk
if (@($osDisk).Count -ne 1) { throw 'CI requires a single OS disk' }
$rawStorage = (& $StorageProbe) -join "`n"
$rawStorage | Set-Content "$Work\storage.log"
$missingSerial = [string]::IsNullOrWhiteSpace($osDisk.SerialNumber) -and $rawStorage -match 'SerialNumberOffset=0 '
$PSNativeCommandUseErrorActionPreference = $false
try {
    foreach ($n in 1..2) {
        & $bin --show-device-info --log "$Work\direct-$n.log"
        $code = $LASTEXITCODE
        if ($missingSerial) {
            if ($code -ne 1 -or (Get-Content -Raw "$Work\direct-$n.log") -notmatch 'stage=system-disk-serial win32=13 schema=win-system-disk-v1 via=direct') {
                throw 'Missing OS disk serial was not explicitly rejected'
            }
        } elseif ($code -ne 0) { throw "Native diagnostic failed: $code" }
    }
} finally { $PSNativeCommandUseErrorActionPreference = $true }
if ($missingSerial) {
    Write-Host 'CI OS disk has no serial: test explicit rejection; TLS uses a separate synthetic IPC fixture (not shipped).'
    $direct = @{ IV_PLAT='win'; IV_USER=[Security.Principal.WindowsIdentity]::GetCurrent().Name;
        IV_INFO='01234567-89AB-CDEF-0123-456789ABCDEF'; IV_DISK='CI-FIXTURE-SYSTEM-DISK' }
} else {
    $direct = Read-Identity "$Work\direct-1.log"
    $repeat = Read-Identity "$Work\direct-2.log"
    Assert-SameHardware $direct $repeat
    if ($direct.IV_USER -ine [Security.Principal.WindowsIdentity]::GetCurrent().Name) { throw 'Wrong initiating user' }
    if ($direct.IV_INFO -ine (Get-CimInstance Win32_ComputerSystemProduct).UUID) { throw 'SMBIOS UUID differs from WMI' }
    if ([int]$direct.disk_number -ne $osDisk.Number) { throw 'Selected disk is not the OS disk' }
    if ($direct.IV_DISK -cne $osDisk.SerialNumber.Trim()) { throw 'Selected disk serial differs from Windows storage API' }
}

Start-Service OpenVPNServiceInteractive
& "$PSScriptRoot\service-probe.ps1" -Work $Work -Name service-admin -ExpectMissingSerial:$missingSerial
if (-not $missingSerial) {
    $service = Read-Identity "$Work\service-admin.log"
    Assert-SameHardware $direct $service
    if ($direct.IV_USER -cne $service.IV_USER) { throw 'Service changed initiating user' }
}

# Use a fresh standard user, authorized only for OpenVPN service access (not local Administrators).
$testUser = 'xy_identity_ci'
$password = ConvertTo-SecureString (([guid]::NewGuid().ToString('N')) + '!Aa9') -AsPlainText -Force
$server = $null
$client = $null
$launcher = $null
try {
    New-LocalUser -Name $testUser -Password $password -AccountNeverExpires | Out-Null
    # GUI normally offers to create this group on first use; MSI only configures its name.
    if (-not (Get-LocalGroup -Name 'OpenVPN Administrators' -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name 'OpenVPN Administrators' | Out-Null
    }
    Add-LocalGroupMember -Group 'OpenVPN Administrators' -Member $testUser
    $account = "$env:COMPUTERNAME\$testUser"
    & icacls.exe $Work /grant "${account}:(OI)(CI)M" | Out-Null
    Copy-Item "$PSScriptRoot\service-probe.ps1" "$Work\service-probe.ps1"
    $credential = [PSCredential]::new($account, $password)
    $probeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Work\service-probe.ps1`"", '-Work', "`"$Work`"", '-Name', 'service-user')
    if ($missingSerial) { $probeArgs += '-ExpectMissingSerial' }
    $probe = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Credential $credential -WorkingDirectory $Work -ArgumentList $probeArgs -PassThru
    if (-not $probe.WaitForExit(45000)) { $probe.Kill(); throw 'Standard-user probe hung' }
    if ($probe.ExitCode -ne 0) { throw "Standard-user probe failed: $($probe.ExitCode)" }
    if (-not $missingSerial) {
        $ordinary = Read-Identity "$Work\service-user.log"
        Assert-SameHardware $direct $ordinary
        if ($ordinary.IV_USER -ine $account) { throw 'Standard-user launch used another identity' }
    }

    # Real loopback TLS handshake using installed binaries. dev null leaves runner routes untouched.
    $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'
    if (-not (Test-Path $openssl)) { throw 'Test OpenSSL missing' }
    Push-Location $Work
    try {
        & $openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 1 -subj /CN=XY-Identity-CI-CA 2>ca-gen.log
        foreach ($role in @('server', 'client')) {
            & $openssl req -newkey rsa:2048 -nodes -keyout "$role.key" -out "$role.csr" -subj "/CN=XY-Identity-CI-$role" 2>"$role-gen.log"
            "basicConstraints=CA:FALSE`nkeyUsage=digitalSignature,keyEncipherment`nextendedKeyUsage=${role}Auth" | Set-Content -Encoding ascii "$role.ext"
            & $openssl x509 -req -in "$role.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile "$role.ext" -out "$role.crt" 2>"$role-sign.log"
        }
        @'
dev null
ifconfig 10.253.0.1 10.253.0.2
ifconfig-noexec
route-noexec
proto udp4
local 127.0.0.1
port 31194
tls-server
ca ca.crt
cert server.crt
key server.key
dh none
disable-dco
data-ciphers AES-256-GCM
verb 4
log server.log
'@ | Set-Content -Encoding ascii server.ovpn
        @'
dev null
ifconfig 10.253.0.2 10.253.0.1
ifconfig-noexec
route-noexec
proto udp4
remote 127.0.0.1 31194
nobind
tls-client
push-peer-info
ca ca.crt
cert client.crt
key client.key
remote-cert-tls server
disable-dco
data-ciphers AES-256-GCM
verb 4
log client.log
'@ | Set-Content -Encoding ascii client.ovpn
        $server = Start-Process $bin -WorkingDirectory $Work -ArgumentList '--config server.ovpn' -PassThru
        if ($missingSerial) {
            $launcher = Start-Process $TlsFixture -WorkingDirectory $Work -ArgumentList "`"$bin`"" -PassThru
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path fixture-client.pid)) {
                if ($launcher.HasExited -or (Get-Date) -gt $deadline) { throw 'TLS fixture did not start installed core' }
                Start-Sleep -Milliseconds 100
            }
            $client = Get-Process -Id ([int](Get-Content -Raw fixture-client.pid).Trim())
        } else {
            $client = Start-Process $bin -WorkingDirectory $Work -ArgumentList '--config client.ovpn' -PassThru
        }
        $deadline = (Get-Date).AddSeconds(40)
        do {
            Start-Sleep -Milliseconds 200
            if ($server.HasExited -or $client.HasExited) { throw 'TLS test process exited early' }
            $serverLog = if (Test-Path server.log) { Get-Content -Raw server.log } else { '' }
            $clientLog = if (Test-Path client.log) { Get-Content -Raw client.log } else { '' }
            if ($serverLog -match 'Initialization Sequence Completed' -and $clientLog -match 'Initialization Sequence Completed') { break }
        } while ((Get-Date) -lt $deadline)
        if ($serverLog -notmatch 'Initialization Sequence Completed' -or $clientLog -notmatch 'Initialization Sequence Completed') { throw 'TLS handshake did not complete' }
        foreach ($key in @('IV_PLAT', 'IV_USER', 'IV_INFO', 'IV_DISK')) {
            $needle = [regex]::Escape("peer info: $key=$($direct[$key])") + '\r?$'
            if (@([regex]::Matches($serverLog, "(?m)$needle")).Count -ne 1) { throw "Server did not receive exactly one native $key" }
        }
        if ($serverLog -notmatch [regex]::Escape("peer info: IV_VER=$expectedVersion")) { throw 'Wire version mismatch' }
        $client.Kill(); $client.WaitForExit(); $client = $null
        if ($launcher) {
            if (-not $launcher.WaitForExit(5000) -or $launcher.ExitCode -ne 0) { throw 'TLS fixture transport failed' }
            $launcher = $null
        }
        $server.Kill(); $server.WaitForExit(); $server = $null

        # A profile cannot override a native identity, including before TLS starts.
        $negative = Start-Process $bin -WorkingDirectory $Work -ArgumentList '--config client.ovpn --setenv IV_DISK override --log conflict.log' -PassThru
        if (-not $negative.WaitForExit(10000)) { $negative.Kill(); throw 'Conflict was not rejected promptly' }
        if ($negative.ExitCode -eq 0 -or (Get-Content -Raw conflict.log) -notmatch 'DEVICE_IDENTITY_CONFIG_CONFLICT') { throw 'Profile identity override was accepted' }
    } finally { Pop-Location }
    $hardwareResult = if ($missingSerial) {
        'CI OS disk has no serial (independent raw descriptor verified); direct/admin-service/standard-user-service all reject it; TLS tests use synthetic hardware via a separate test-only pipe launcher. Physical hardware and reboot validation remain required.'
    } else { 'Native hardware validated against WMI/storage API; repeated diagnostics and admin/standard-user service identities match; TLS uses actual native hardware.' }
    "PASS: installed MSI; service protocol; TLS peer-info; profile conflict rejection. $hardwareResult" | Set-Content "$Work\result.log"
    Get-Content "$Work\result.log"
} finally {
    foreach ($process in @($client, $server, $launcher)) { if ($process -and -not $process.HasExited) { $process.Kill() } }
    Remove-LocalUser -Name $testUser -ErrorAction SilentlyContinue
    # Ephemeral private keys are never part of the uploaded *.log diagnostics.
    Remove-Item "$Work\*.key" -ErrorAction SilentlyContinue
}
