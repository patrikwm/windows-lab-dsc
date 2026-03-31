#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates 3 Hyper-V VMs from a Windows Server VHD base image.
.DESCRIPTION
    Copies the base VHD for each VM, injects a per-VM unattend.xml to skip OOBE
    and configure static IP/hostname, then boots. No manual clicks needed.
.PARAMETER VhdPath
    Path to the Windows Server 2022 Evaluation VHD.
.PARAMETER VmPath
    Directory for VM files. Default: C:\fastdisk\hyper-v
#>
param(
    [Parameter(Mandatory)]
    [string]$VhdPath,

    [string]$VmPath = "C:\fastdisk\hyper-v"
)

$ErrorActionPreference = "Continue"

# Try common switch names
$SwitchName = $null
foreach ($name in @("External-LAN", "WinLab", "Default Switch")) {
    if (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue) { $SwitchName = $name; break }
}
if (-not $SwitchName) {
    Write-Host "No known Hyper-V switch found. Available:" -ForegroundColor Yellow
    Get-VMSwitch | Format-Table Name, SwitchType -AutoSize
    $SwitchName = Read-Host "Enter switch name"
}
Write-Host "Using switch: $SwitchName" -ForegroundColor Cyan

if (-not (Test-Path $VhdPath)) {
    Write-Error "VHD not found: $VhdPath"
    exit 1
}

$VMs = @(
    @{ Name = "LAB-DC";             IP = "192.168.2.50"; DNS = "8.8.8.8";        Gateway = "192.168.2.1" }
    @{ Name = "LAB-CLIENT-1";       IP = "192.168.2.51"; DNS = "192.168.2.50";   Gateway = "192.168.2.1" }
    @{ Name = "LAB-CLIENT-2";       IP = "192.168.2.52"; DNS = "192.168.2.50";   Gateway = "192.168.2.1" }
    @{ Name = "LAB-LOCAL-1"; IP = "192.168.2.53"; DNS = "8.8.8.8";        Gateway = "192.168.2.1" }
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$UnattendTemplate = Join-Path $RepoRoot "autounattend\oobe-unattend.xml"

if (-not (Test-Path $UnattendTemplate)) {
    Write-Error "Unattend template not found: $UnattendTemplate"
    exit 1
}

foreach ($vm in $VMs) {
    $vmName = $vm.Name
    Write-Host "Creating VM: $vmName..." -ForegroundColor Cyan

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "  VM '$vmName' already exists, skipping." -ForegroundColor Yellow
        continue
    }

    # Create VM directory and copy base VHD
    $vmDir = Join-Path $VmPath $vmName
    if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }
    $vhdDest = Join-Path $vmDir "$vmName.vhd"

    if (-not (Test-Path $vhdDest)) {
        Write-Host "  Copying base VHD (~10GB)..." -ForegroundColor Gray
        Copy-Item -Path $VhdPath -Destination $vhdDest
    }

    # Generate per-VM unattend.xml from template
    $xmlContent = Get-Content $UnattendTemplate -Raw
    $xmlContent = $xmlContent -replace '\$\{COMPUTER_NAME\}', $vmName
    $xmlContent = $xmlContent -replace '\$\{IP_ADDRESS\}', $vm.IP
    $xmlContent = $xmlContent -replace '\$\{DNS_SERVER\}', $vm.DNS
    $xmlContent = $xmlContent -replace '\$\{GATEWAY\}', $vm.Gateway

    # Mount VHD and inject files
    Write-Host "  Injecting unattend.xml + oobe-setup.ps1..." -ForegroundColor Gray
    Mount-VHD -Path $vhdDest
    Start-Sleep -Seconds 3

    # Find the Windows partition by checking all drive letters
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

        # Inject unattend.xml
        $xmlContent | Set-Content -Path "$pantherDir\unattend.xml" -Encoding UTF8

        # Inject oobe-setup.ps1 (with per-VM variable substitution)
        $setupTemplate = Join-Path $RepoRoot "autounattend\oobe-setup.ps1"
        if (Test-Path $setupTemplate) {
            $setupContent = Get-Content $setupTemplate -Raw
            $setupContent = $setupContent -replace '\$\{IP_ADDRESS\}', $vm.IP
            $setupContent = $setupContent -replace '\$\{DNS_SERVER\}', $vm.DNS
            $setupContent = $setupContent -replace '\$\{GATEWAY\}', $vm.Gateway
            $setupContent | Set-Content -Path "$pantherDir\oobe-setup.ps1" -Encoding UTF8
        }

        Write-Host "  Injected to $pantherDir" -ForegroundColor Gray
    } else {
        Write-Warning "  Could not find Windows partition! OOBE will not be automated."
    }

    Dismount-VHD -Path $vhdDest

    # Create Gen1 VM (VHD is MBR format)
    New-VM -Name $vmName `
        -MemoryStartupBytes 4GB `
        -VHDPath $vhdDest `
        -SwitchName $SwitchName `
        -Generation 1 `
        -Path $VmPath | Out-Null

    Set-VM -Name $vmName -ProcessorCount 2 -AutomaticCheckpointsEnabled $false

    Write-Host "  Created: $vmName ($($vm.IP))" -ForegroundColor Green
}

# Start all VMs
Write-Host ""
Write-Host "Starting all VMs..." -ForegroundColor Cyan
foreach ($vm in $VMs) {
    $state = (Get-VM -Name $vm.Name).State
    if ($state -ne 'Running') {
        Start-VM -Name $vm.Name
        Write-Host "  Started $($vm.Name)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "All VMs created and started." -ForegroundColor Green
Write-Host "OOBE will complete automatically (unattend.xml injected)."
Write-Host "Each VM will set its hostname, static IP, enable WinRM + RDP."
Write-Host ""
Write-Host "Run 03-Wait-ForInstall.ps1 to wait until all VMs are ready."
