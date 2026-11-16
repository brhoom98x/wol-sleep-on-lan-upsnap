<#
.SYNOPSIS
    Checks everything this PC needs for remote wake, sleep and shutdown, and reports
    what is wrong. Read-only — changes nothing.

.DESCRIPTION
    Runs fine without elevation, though a couple of checks report "needs admin" instead
    of a result. Covers the Windows side only; it cannot see BIOS settings, which are a
    common cause of failure. See Stage 1 of the README for those.

.EXAMPLE
    .\check-readiness.ps1
    .\check-readiness.ps1 -Port 8009
#>
[CmdletBinding()]
param(
    [string] $AdapterName,
    [int]    $Port = 8009
)

function Write-Check {
    param([string] $Label, [bool] $Ok, [string] $Detail, [switch] $Warn)
    $mark  = if ($Ok) { '  OK  ' } elseif ($Warn) { ' WARN ' } else { ' FAIL ' }
    $color = if ($Ok) { 'Green' } elseif ($Warn) { 'Yellow' } else { 'Red' }
    Write-Host "[$mark] " -ForegroundColor $color -NoNewline
    Write-Host $Label -NoNewline
    if ($Detail) { Write-Host "  — $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
}

$elevated = ([Security.Principal.WindowsPrincipal] `
             [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host 'Remote power readiness' -ForegroundColor Cyan
Write-Host '======================' -ForegroundColor Cyan
if (-not $elevated) { Write-Host 'Running unelevated — some checks are limited.' -ForegroundColor DarkGray }
Write-Host ''

# --- adapter ----------------------------------------------------------------
if (-not $AdapterName) {
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
         Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|VMware|Hyper-V|TAP|Tailscale' } |
         Select-Object -First 1
} else {
    $a = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
}

if (-not $a) {
    Write-Check 'Wired adapter found' $false 'no physical adapter is Up'
    return
}
Write-Check 'Wired adapter found' $true "$($a.Name) — $($a.MacAddress)"

$ip = (Get-NetIPAddress -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Select-Object -First 1).IPAddress
Write-Check 'Has an IPv4 address' ([bool]$ip) $ip

# --- driver properties ------------------------------------------------------
$props = Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue
function Prop([string]$kw) { ($props | Where-Object RegistryKeyword -eq $kw).RegistryValue }

$magic = Prop '*WakeOnMagicPacket'
Write-Check 'Wake on Magic Packet (S3/S4)' ($magic -eq 1) $(if ($null -eq $magic) { 'property absent' } else { "value=$magic" })

$pme    = Prop 'EnablePME'
$rtlS5  = Prop 'ShutdownWakeOnLan'
if ($null -ne $pme) {
    Write-Check 'Enable PME (S5 — Intel)' ($pme -eq 1) "value=$pme"
} elseif ($null -ne $rtlS5) {
    Write-Check 'Shutdown Wake-On-Lan (S5 — Realtek)' ($rtlS5 -eq 1) "value=$rtlS5"
} else {
    Write-Check 'S5 wake property' $false 'not exposed by this driver — check BIOS instead' -Warn
}

$pattern = Prop '*WakeOnPattern'
if ($null -ne $pattern) {
    Write-Check 'Wake on Pattern Match disabled' ($pattern -eq 0) "value=$pattern (1 causes random wakes)" -Warn:($pattern -eq 1)
}

# --- wake armed -------------------------------------------------------------
$armed = (powercfg /devicequery wake_armed) -join "`n"
Write-Check 'Adapter armed to wake the PC' ($armed -match [regex]::Escape($a.InterfaceDescription)) 'powercfg /devicequery wake_armed'

# --- fast startup -----------------------------------------------------------
$hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
Write-Check 'Fast Startup off' ($hb -eq 0) $(if ($null -eq $hb) { 'not set (treated as off)' } else { "HiberbootEnabled=$hb" }) -Warn:($hb -eq 1)

# --- hibernation ------------------------------------------------------------
$pa = (powercfg /a) -join "`n"
$hib = $pa -match 'Hibernate' -and $pa -notmatch 'Hibernation has not been enabled'
Write-Check 'Sleep behaviour' $true $(if ($hib) { '/sleep will HIBERNATE (S4), not sleep (S3)' } else { '/sleep gives real S3 standby' })

# --- ICMP -------------------------------------------------------------------
$echo = Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Echo Request*ICMPv4*' -and $_.Enabled -eq 'True' }
Write-Check 'Answers ping (UpSnap online check)' ([bool]$echo) `
    $(if ($echo) { "$($echo.Count) rule(s) enabled" } else { 'UpSnap will show this PC as OFF and hide its buttons' })

# --- SOL --------------------------------------------------------------------
$sol = Get-Process sol -ErrorAction SilentlyContinue
Write-Check 'Sleep-On-LAN running' ([bool]$sol) $(if ($sol) { "PID $($sol.Id)" } else { 'not running' })

if ($sol) {
    try {
        $xml = [xml](Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 5).Content
        $ops = ($xml.result.commands.command | ForEach-Object { '/' + $_.operation }) -join ' '
        Write-Check "SOL answering on $Port" $true $ops
    } catch {
        Write-Check "SOL answering on $Port" $false $_.Exception.Message
    }
}

$fw = Get-NetFirewallRule -DisplayName 'Sleep-On-LAN*' -ErrorAction SilentlyContinue
if ($fw) {
    $scope = ($fw | ForEach-Object { ($_ | Get-NetFirewallAddressFilter).RemoteAddress }) | Select-Object -Unique
    $open  = $scope -contains 'Any'
    Write-Check 'SOL firewall scoped' (-not $open) "remote=$($scope -join ',')" -Warn:$open
} else {
    Write-Check 'SOL firewall rules exist' $false 'no Sleep-On-LAN rules found'
}

Write-Host ''
Write-Host 'This cannot see BIOS settings. If wake-from-shutdown fails with everything' -ForegroundColor DarkGray
Write-Host 'above green, the cause is almost certainly ErP Ready — see Stage 1.' -ForegroundColor DarkGray
Write-Host ''
