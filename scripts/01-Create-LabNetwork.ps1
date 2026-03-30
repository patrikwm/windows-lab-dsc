#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the Hyper-V network for the lab.
.DESCRIPTION
    Creates an External virtual switch "WinLab" bridged to a physical network adapter.
    VMs get IPs on the 192.168.2.0/24 LAN (DC=.51, Client=.52, Standalone=.53).
    The host can RDP to VMs directly on the LAN.
.PARAMETER NetAdapterName
    Name of the physical network adapter to bridge. If not specified, the first
    connected Ethernet/Wi-Fi adapter is used.
#>
param(
    [string]$NetAdapterName
)

$ErrorActionPreference = "Stop"
$SwitchName = "WinLab"

Write-Host "Creating lab network..." -ForegroundColor Cyan

# Find a suitable physical adapter if not specified
if (-not $NetAdapterName) {
    $adapter = Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Hyper-V*' -and $_.InterfaceDescription -notlike '*Virtual*'
    } | Select-Object -First 1

    if (-not $adapter) {
        Write-Error "No connected physical network adapter found. Specify one with -NetAdapterName."
        exit 1
    }
    $NetAdapterName = $adapter.Name
    Write-Host "Using adapter: $NetAdapterName ($($adapter.InterfaceDescription))" -ForegroundColor Gray
}

# Create external virtual switch
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Write-Host "Switch '$SwitchName' already exists." -ForegroundColor Green
} else {
    New-VMSwitch -Name $SwitchName -NetAdapterName $NetAdapterName -AllowManagementOS $true | Out-Null
    Write-Host "Created external switch '$SwitchName' bridged to '$NetAdapterName'." -ForegroundColor Green
}

# Set TrustedHosts for WinRM to lab VMs
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.2.*" -Force
Write-Host "Set WinRM TrustedHosts to '192.168.2.*'." -ForegroundColor Green

Write-Host ""
Write-Host "Lab network ready:" -ForegroundColor Green
Write-Host "  Switch: $SwitchName (External, bridged to $NetAdapterName)"
Write-Host "  VMs will be reachable at 192.168.2.51, 192.168.2.52, 192.168.2.53"
