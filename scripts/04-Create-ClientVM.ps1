#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates an additional LAB-CLIENT VM for testing.
.DESCRIPTION
    Copies the base Windows Server VHD, injects unattend.xml with the specified
    hostname and IP, creates a Hyper-V VM, and starts it.
    After boot (~5 min), the VM will have RDP, WinRM, and SSH enabled.
.PARAMETER Name
    VM name. Default: LAB-CLIENT-2
.PARAMETER IP
    Static IP address. Default: 192.168.2.122
.PARAMETER DNS
    DNS server. Default: 192.168.2.121 (LAB-DC)
.PARAMETER Gateway
    Default gateway. Default: 192.168.2.1
.PARAMETER VmPath
    Directory for VM files. Default: C:\fastdisk\hyper-v
.PARAMETER BaseVhd
    Path to the base Windows Server VHD. Default: C:\fastdisk\hyper-v\iso\windows-server-2022-eval.vhd
.PARAMETER SwitchName
    Hyper-V switch name. Default: External-LAN
.EXAMPLE
    .\04-Create-ClientVM.ps1
    .\04-Create-ClientVM.ps1 -Name "LAB-CLIENT-3" -IP "192.168.2.123"
#>
param(
    [string]$Name = "LAB-CLIENT-2",
    [string]$IP = "192.168.2.122",
    [string]$DNS = "192.168.2.121",
    [string]$Gateway = "192.168.2.1",
    [string]$VmPath = "C:\fastdisk\hyper-v",
    [string]$BaseVhd = "C:\fastdisk\hyper-v\iso\windows-server-2022-eval.vhd",
    [string]$SwitchName = "External-LAN"
)

$ErrorActionPreference = "Stop"

# Validate
if (-not (Test-Path $BaseVhd)) {
    Write-Error "Base VHD not found: $BaseVhd"
    exit 1
}

# Find the switch - try common names
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
    Write-Host "Switch '$SwitchName' not found. Available switches:" -ForegroundColor Yellow
    Get-VMSwitch | Format-Table Name, SwitchType -AutoSize
    $SwitchName = Read-Host "Enter switch name to use"
    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Host "VM '$Name' already exists." -ForegroundColor Yellow
    $confirm = Read-Host "Delete and recreate? (y/N)"
    if ($confirm -eq 'y') {
        Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $Name -Force
        $vmDir = Join-Path $VmPath $Name
        if (Test-Path $vmDir) { Remove-Item $vmDir -Recurse -Force }
        Write-Host "Removed old VM." -ForegroundColor Green
    } else {
        exit 0
    }
}

Write-Host "Creating VM: $Name ($IP)..." -ForegroundColor Cyan

# Create VM directory and copy base VHD
$vmDir = Join-Path $VmPath $Name
if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }
$vhdDest = Join-Path $vmDir "$Name.vhd"

if (-not (Test-Path $vhdDest)) {
    Write-Host "  Copying base VHD (~10GB, this takes a minute)..." -ForegroundColor Gray
    Copy-Item -Path $BaseVhd -Destination $vhdDest
    Write-Host "  VHD copied." -ForegroundColor Green
}

# Generate unattend.xml from template
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$UnattendTemplate = Join-Path $RepoRoot "autounattend\oobe-unattend.xml"

if (-not (Test-Path $UnattendTemplate)) {
    Write-Error "Unattend template not found: $UnattendTemplate"
    exit 1
}

$xmlContent = Get-Content $UnattendTemplate -Raw
$xmlContent = $xmlContent -replace '\$\{COMPUTER_NAME\}', $Name
$xmlContent = $xmlContent -replace '\$\{IP_ADDRESS\}', $IP
$xmlContent = $xmlContent -replace '\$\{DNS_SERVER\}', $DNS
$xmlContent = $xmlContent -replace '\$\{GATEWAY\}', $Gateway

# Mount VHD and inject unattend
Write-Host "  Mounting VHD and injecting unattend.xml..." -ForegroundColor Gray
Mount-VHD -Path $vhdDest
Start-Sleep -Seconds 3

$drive = $null
$vhdInfo = Get-VHD -Path $vhdDest
$partitions = Get-Partition -DiskNumber $vhdInfo.DiskNumber -ErrorAction SilentlyContinue
foreach ($p in $partitions) {
    if ($p.DriveLetter -and (Test-Path "$($p.DriveLetter):\Windows")) {
        $drive = "$($p.DriveLetter):"
        break
    }
}

if ($drive) {
    $pantherDir = "$drive\Windows\Panther"
    if (-not (Test-Path $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }
    $xmlContent | Set-Content -Path "$pantherDir\unattend.xml" -Encoding UTF8
    Write-Host "  Injected unattend.xml to $pantherDir" -ForegroundColor Green
} else {
    Write-Warning "  Could not find Windows partition!"
}

Dismount-VHD -Path $vhdDest

# Create Gen1 VM
New-VM -Name $Name `
    -MemoryStartupBytes 4GB `
    -VHDPath $vhdDest `
    -SwitchName $SwitchName `
    -Generation 1 `
    -Path $VmPath | Out-Null

Set-VM -Name $Name -ProcessorCount 2 -AutomaticCheckpointsEnabled $false

# Start it
Start-VM -Name $Name
Write-Host "  VM started." -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  $Name created successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  IP:       $IP"
Write-Host "  DNS:      $DNS"
Write-Host "  Gateway:  $Gateway"
Write-Host "  User:     labadmin"
Write-Host "  Password: ChangeMe!2024#Secure"
Write-Host ""
Write-Host "  The VM will take ~5 minutes to complete OOBE."
Write-Host "  After that, you can connect via:"
Write-Host "    RDP:   mstsc /v:$IP"
Write-Host "    WinRM: Enter-PSSession -ComputerName $IP -Credential labadmin"
Write-Host ""
Write-Host "  To join the domain (optional):"
Write-Host "    Add-Computer -DomainName lab.test -Credential LAB\labadmin -Restart"
Write-Host ""
Write-Host "  To install Mideye (after VM is ready):"
Write-Host "    .\infra\Deploy-MideyeCP.ps1 -Servers $IP -User labadmin -Password 'ChangeMe!2024#Secure'"
Write-Host ""
