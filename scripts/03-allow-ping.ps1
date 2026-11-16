#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Lets this PC answer ping, so UpSnap can tell it is online.

.DESCRIPTION
    UpSnap decides whether a device is online by pinging it, and hides the sleep and
    shutdown buttons on any device it believes is off. Windows blocks inbound ICMP
    echo by default, so a perfectly healthy PC shows as powered down with no controls.

    Verify from ANOTHER machine afterwards. Local traffic bypasses the firewall, so
    this PC can always ping its own address and will report success even while every
    other host on the network gets nothing.

.PARAMETER RemoteAddress
    Restrict who may ping, e.g. the UpSnap host. Default 'Any'.

.PARAMETER IncludePublic
    Also allow it on the Public profile. Off by default — on an untrusted network
    you normally do not want to answer pings.

.EXAMPLE
    .\03-allow-ping.ps1
    .\03-allow-ping.ps1 -RemoteAddress 192.168.1.50
#>
[CmdletBinding()]
param(
    [string] $RemoteAddress = 'Any',
    [switch] $IncludePublic
)

$ErrorActionPreference = 'Stop'

Write-Host 'Inbound ICMP echo rules, before:' -ForegroundColor Cyan
Get-NetFirewallRule -Direction Inbound |
    Where-Object DisplayName -like '*Echo Request*ICMP*' |
    Format-Table DisplayName, Enabled, Profile -AutoSize

$rules = Get-NetFirewallRule -Direction Inbound |
         Where-Object { $_.DisplayName -like 'File and Printer Sharing (Echo Request*' }

if (-not $IncludePublic) {
    $rules = $rules | Where-Object { $_.Profile -notmatch '^Public$' }
}

if (-not $rules) { throw 'No matching echo-request rules found.' }

Write-Host "Enabling $($rules.Count) rule(s)..." -ForegroundColor Cyan
$rules | Enable-NetFirewallRule

if ($RemoteAddress -ne 'Any') {
    Write-Host "Restricting to $RemoteAddress" -ForegroundColor Cyan
    $rules | Set-NetFirewallRule -RemoteAddress $RemoteAddress
}

Write-Host ''
Write-Host 'After:' -ForegroundColor Green
Get-NetFirewallRule -Direction Inbound |
    Where-Object { $_.DisplayName -like '*Echo Request*ICMP*' -and $_.Enabled -eq 'True' } |
    Format-Table DisplayName, Enabled, Profile -AutoSize

$ip = (Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
       Select-Object -First 1).IPAddress

Write-Host ''
Write-Host "Now ping $ip from another machine. Pinging it from here proves nothing." -ForegroundColor Yellow
