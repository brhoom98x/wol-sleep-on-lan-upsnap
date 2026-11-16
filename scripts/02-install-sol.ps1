#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Sleep-On-LAN and registers it as a SYSTEM scheduled task that starts at boot.

.DESCRIPTION
    sol.exe is a plain console binary, so `sc.exe create` fails with error 1053 when it
    does not answer the service control manager. The usual workaround is NSSM - another
    unsigned binary to get past antivirus. An AtStartup scheduled task running as SYSTEM
    does the same job with nothing extra on disk: starts at boot with no login, survives
    logoff, and has the rights to call the shutdown and suspend APIs.

    You must download sol.exe yourself from
    https://github.com/SR-G/sleep-on-lan/releases and pass it with -SolExe, or place it
    in -InstallDir beforehand. This script deliberately does not download anything.

.PARAMETER UpSnapAddress
    Address allowed to reach the SOL ports. REQUIRED: SOL has no authentication, so the
    firewall scope is the only thing protecting the endpoint. Pass 'Any' at your own risk.

.PARAMETER SolExe
    Path to the downloaded sol.exe. Copied into -InstallDir.

.PARAMETER ConfigFile
    Path to a sol.json. Defaults to examples/sol.windows.json in this repo.

.PARAMETER InstallDir
    Where to install. Default C:\Tools\sleep-on-lan.

.PARAMETER Port
    HTTP port SOL listens on. Default 8009. Must match sol.json and UpSnap's SOL Port.

.EXAMPLE
    .\02-install-sol.ps1 -UpSnapAddress 192.168.1.50 -SolExe ~\Downloads\sol.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UpSnapAddress,
    [string] $SolExe,
    [string] $ConfigFile = (Join-Path $PSScriptRoot '..\examples\sol.windows.json'),
    [string] $InstallDir = 'C:\Tools\sleep-on-lan',
    [int]    $Port       = 8009,
    [string] $TaskName   = 'SleepOnLAN'
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# --- binary -----------------------------------------------------------------
$target = Join-Path $InstallDir 'sol.exe'
if ($SolExe) {
    if (-not (Test-Path $SolExe)) { throw "Not found: $SolExe" }
    Copy-Item $SolExe $target -Force
    Write-Host "[1/5] Copied sol.exe into $InstallDir" -ForegroundColor Cyan
} elseif (Test-Path $target) {
    Write-Host "[1/5] Using the sol.exe already in $InstallDir" -ForegroundColor Cyan
} else {
    throw "No sol.exe. Download it from https://github.com/SR-G/sleep-on-lan/releases and pass -SolExe."
}

# --- config -----------------------------------------------------------------
if (-not (Test-Path $ConfigFile)) { throw "Config not found: $ConfigFile" }
Copy-Item $ConfigFile (Join-Path $InstallDir 'sol.json') -Force
Write-Host "[2/5] Installed sol.json" -ForegroundColor Cyan
Write-Host "      Edit $InstallDir\sol.json to set BroadcastIP for your subnet." -ForegroundColor DarkGray

# --- firewall ---------------------------------------------------------------
Write-Host "[3/5] Firewall rules (source: $UpSnapAddress)" -ForegroundColor Cyan
if ($UpSnapAddress -eq 'Any') {
    Write-Warning '  Allowing ANY source. Anyone who can reach this port can shut the PC down.'
}
Remove-NetFirewallRule -DisplayName 'Sleep-On-LAN*' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'Sleep-On-LAN HTTP' -Direction Inbound -Protocol TCP `
    -LocalPort $Port -RemoteAddress $UpSnapAddress -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'Sleep-On-LAN UDP' -Direction Inbound -Protocol UDP `
    -LocalPort 9 -RemoteAddress $UpSnapAddress -Action Allow -Profile Any | Out-Null

# --- scheduled task ---------------------------------------------------------
Write-Host '[4/5] Registering the SYSTEM startup task' -ForegroundColor Cyan
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-Process sol -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$action    = New-ScheduledTaskAction -Execute $target -WorkingDirectory $InstallDir
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                -MultipleInstances IgnoreNew
$settings.ExecutionTimeLimit = 'PT0S'   # the cmdlet parameter is unreliable across versions

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description 'Sleep-On-LAN daemon' -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 4

# --- verify -----------------------------------------------------------------
Write-Host '[5/5] Verifying' -ForegroundColor Cyan
try {
    $xml = [xml](Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 5).Content
    Write-Host '  Listeners:' -ForegroundColor Green
    $xml.result.listeners.listener | ForEach-Object { '    {0}:{1} active={2}' -f $_.type, $_.port, $_.active }
    Write-Host '  Commands:' -ForegroundColor Green
    $xml.result.commands.command | ForEach-Object { '    /{0}' -f $_.operation }
    Write-Host ''
    Write-Host 'SOL is up and will start at boot.' -ForegroundColor Green
} catch {
    Write-Warning "No answer on port $Port : $($_.Exception.Message)"
    Write-Warning 'Check antivirus quarantine first - sol.exe is unsigned and opens a listener.'
    Write-Warning "To see the error directly:  cd '$InstallDir' ; .\sol.exe"
}

Write-Host ''
Write-Host 'Note: querying this task from a NON-elevated prompt reports "Access is denied"' -ForegroundColor DarkGray
Write-Host 'or "not found", because a SYSTEM task is hidden from ordinary users. That does' -ForegroundColor DarkGray
Write-Host 'not mean it failed.' -ForegroundColor DarkGray
