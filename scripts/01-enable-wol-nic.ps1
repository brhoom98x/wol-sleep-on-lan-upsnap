#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets every Wake-on-LAN driver property your network card exposes, including the
    S5 (full shutdown) one that most guides miss.

.DESCRIPTION
    "Wake on Magic Packet" only covers S3/S4. Waking from a full shutdown needs a
    second property with a vendor-specific name - "Enable PME" on Intel,
    "Shutdown Wake-On-Lan" on Realtek. This sets whichever ones exist.

    Properties not present on your driver are skipped silently; no card has all of them.

.PARAMETER AdapterName
    Name of the wired adapter. Defaults to the only physical adapter that is Up.

.PARAMETER DisableFastStartup
    Also turn off Fast Startup, which otherwise tears the card down at shutdown.
    This disables hibernation too.

.EXAMPLE
    .\01-enable-wol-nic.ps1
    .\01-enable-wol-nic.ps1 -AdapterName 'Ethernet 2' -DisableFastStartup
#>
[CmdletBinding()]
param(
    [string] $AdapterName,
    [switch] $DisableFastStartup
)

$ErrorActionPreference = 'Stop'

# --- pick the adapter -------------------------------------------------------
if (-not $AdapterName) {
    $candidates = Get-NetAdapter -Physical |
                  Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|VMware|Hyper-V|TAP|Tailscale|Loopback' }

    if ($candidates.Count -eq 0) { throw 'No physical adapter is Up. Pass -AdapterName explicitly.' }
    if ($candidates.Count -gt 1) {
        Write-Host 'Several physical adapters are up:' -ForegroundColor Yellow
        $candidates | Format-Table Name, InterfaceDescription, MacAddress -AutoSize
        throw 'Ambiguous. Re-run with -AdapterName.'
    }
    $AdapterName = $candidates[0].Name
}

$adapter = Get-NetAdapter -Name $AdapterName
Write-Host "Adapter: $($adapter.Name) - $($adapter.InterfaceDescription)" -ForegroundColor Cyan
Write-Host "MAC:     $($adapter.MacAddress)   <- this is what UpSnap needs" -ForegroundColor Cyan
Write-Host ''

# --- driver properties ------------------------------------------------------
# Keyword               Desired  Why
$wanted = [ordered]@{
    '*WakeOnMagicPacket'   = 1   # wake from S3/S4
    'EnablePME'            = 1   # Intel:   wake from S5
    'ShutdownWakeOnLan'    = 1   # Realtek: wake from S5
    '*WakeOnPattern'       = 0   # stop random traffic waking the PC
    'EEELinkAdvertisement' = 0   # Energy Efficient Ethernet
    '*EEE'                 = 0
    'GreenEthernet'        = 0
    'WakeOnSlot'           = 1
}

$present = Get-NetAdapterAdvancedProperty -Name $AdapterName |
           Select-Object -ExpandProperty RegistryKeyword

foreach ($kw in $wanted.Keys) {
    if ($present -notcontains $kw) {
        Write-Host ("  {0,-22} not present on this driver" -f $kw) -ForegroundColor DarkGray
        continue
    }
    try {
        Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $kw `
            -RegistryValue $wanted[$kw] -NoRestart -Confirm:$false
        Write-Host ("  {0,-22} -> {1}" -f $kw, $wanted[$kw]) -ForegroundColor Green
    } catch {
        Write-Warning ("  {0,-22} failed: {1}" -f $kw, $_.Exception.Message)
    }
}

# --- device-level wake permission ------------------------------------------
Write-Host ''
Write-Host 'Enabling device wake permission...' -ForegroundColor Cyan
try {
    Enable-NetAdapterPowerManagement -Name $AdapterName -WakeOnMagicPacket -ErrorAction Stop
    Write-Host '  WakeOnMagicPacket armed' -ForegroundColor Green
} catch {
    Write-Warning "  Could not set it via PowerShell: $($_.Exception.Message)"
    Write-Warning '  Set it by hand: Device Manager -> adapter -> Power Management tab.'
}

Write-Host ''
Write-Host 'Restarting the adapter (brief network drop)...' -ForegroundColor Cyan
Restart-NetAdapter -Name $AdapterName -Confirm:$false
Start-Sleep -Seconds 6

# --- optional: Fast Startup -------------------------------------------------
if ($DisableFastStartup) {
    Write-Host ''
    Write-Host 'Disabling Fast Startup (and hibernation)...' -ForegroundColor Cyan
    powercfg /hibernate off
}

# --- verify -----------------------------------------------------------------
Write-Host ''
Write-Host '--- Result ---' -ForegroundColor Cyan
Get-NetAdapterAdvancedProperty -Name $AdapterName |
    Where-Object { $wanted.Keys -contains $_.RegistryKeyword } |
    Format-Table DisplayName, DisplayValue -AutoSize

Write-Host 'Devices armed to wake this PC:' -ForegroundColor Cyan
powercfg /devicequery wake_armed

Write-Host ''
Write-Host "The adapter must appear in that list. If it doesn't, the Power Management" -ForegroundColor Yellow
Write-Host 'checkbox did not take - set it by hand in Device Manager.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Remember: BIOS settings matter too. See Stage 1 of the README.' -ForegroundColor Yellow
