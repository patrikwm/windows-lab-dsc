#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the Hyper-V NAT network for the lab.
.DESCRIPTION
    Creates an Internal virtual switch "WinLab" with a NAT gateway at 10.0.0.1/24.
    VMs get internet via NetNat. The host can RDP to VMs at 10.0.0.10/20/30.
#>

$ErrorActionPreference = "Stop"
$SwitchName = "WinLab"
$GatewayIP = "10.0.0.1"
$Prefix = 24
$NatName = "WinLabNAT"
$Subnet = "10.0.0.0/24"

Write-Host "Creating lab network..." -ForegroundColor Cyan

# Check for existing NetNat (Windows allows only one)
$existingNat = Get-NetNat -ErrorAction SilentlyContinue
if ($existingNat -and $existingNat.Name -ne $NatName) {
    Write-Host "WARNING: An existing NetNat '$($existingNat.Name)' was found." -ForegroundColor Yellow
    Write-Host "Windows only supports one NetNat. Remove it first or this script will fail." -ForegroundColor Yellow
    $confirm = Read-Host "Remove existing NetNat '$($existingNat.Name)'? (y/N)"
    if ($confirm -eq 'y') {
        Remove-NetNat -Name $existingNat.Name -Confirm:$false
        Write-Host "Removed." -ForegroundColor Green
    } else {
        Write-Host "Aborted." -ForegroundColor Red
        exit 1
    }
}

# Create virtual switch
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Write-Host "Switch '$SwitchName' already exists." -ForegroundColor Green
} else {
    New-VMSwitch -SwitchType Internal -Name $SwitchName | Out-Null
    Write-Host "Created switch '$SwitchName'." -ForegroundColor Green
}

# Get the host-side adapter for the switch
$adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }
if (-not $adapter) {
    Write-Error "Could not find network adapter for switch '$SwitchName'."
    exit 1
}

# Assign gateway IP to host
$existingIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $GatewayIP -ErrorAction SilentlyContinue
if ($existingIP) {
    Write-Host "Gateway IP $GatewayIP already assigned." -ForegroundColor Green
} else {
    New-NetIPAddress -IPAddress $GatewayIP -PrefixLength $Prefix -InterfaceIndex $adapter.ifIndex | Out-Null
    Write-Host "Assigned $GatewayIP/$Prefix to host." -ForegroundColor Green
}

# Create NAT
if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
    Write-Host "NAT '$NatName' already exists." -ForegroundColor Green
} else {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $Subnet | Out-Null
    Write-Host "Created NAT '$NatName' for $Subnet." -ForegroundColor Green
}

# Set TrustedHosts for WinRM to lab VMs
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "10.0.0.*" -Force
Write-Host "Set WinRM TrustedHosts to '10.0.0.*'." -ForegroundColor Green

Write-Host ""
Write-Host "Lab network ready:" -ForegroundColor Green
Write-Host "  Switch: $SwitchName (Internal)"
Write-Host "  Gateway: $GatewayIP/$Prefix"
Write-Host "  NAT: $NatName ($Subnet)"
Write-Host "  VMs will be reachable at 10.0.0.10, 10.0.0.20, 10.0.0.30"
