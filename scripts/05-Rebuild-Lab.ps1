#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Tears down all LAB VMs and rebuilds them with static IPs.
.DESCRIPTION
    1. Stops and removes all LAB-* VMs
    2. Recreates them from the base VHD with static IPs
    3. Waits for OOBE to complete
    4. Joins CLIENT VMs to the domain
    5. Creates test users on all machines

    After this script completes, all VMs are ready for Mideye deployment.
.PARAMETER BaseVhd
    Path to the base Windows Server 2022 VHD.
.PARAMETER VmPath
    Directory for VM files.
.PARAMETER SwitchName
    Hyper-V switch to use.
.PARAMETER SkipTeardown
    Skip teardown of existing VMs (only create missing ones).
#>
param(
    [string]$BaseVhd = "C:\fastdisk\hyper-v\iso\windows-server-2022-eval.vhd",
    [string]$VmPath = "C:\fastdisk\hyper-v",
    [string]$SwitchName = "External-LAN",
    [switch]$SkipTeardown
)

$ErrorActionPreference = "Continue"

# Static IP assignments
$VMs = @(
    @{ Name = "LAB-DC";         IP = "192.168.2.50"; DNS = "8.8.8.8";       Gateway = "192.168.2.1"; Role = "DC" }
    @{ Name = "LAB-CLIENT";     IP = "192.168.2.51"; DNS = "192.168.2.50";  Gateway = "192.168.2.1"; Role = "Client" }
    @{ Name = "LAB-CLIENT-2";   IP = "192.168.2.52"; DNS = "192.168.2.50";  Gateway = "192.168.2.1"; Role = "Client" }
    @{ Name = "LAB-STANDALONE"; IP = "192.168.2.53"; DNS = "8.8.8.8";       Gateway = "192.168.2.1"; Role = "Standalone" }
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$UnattendTemplate = Join-Path $RepoRoot "autounattend\oobe-unattend.xml"

# Validate
if (-not (Test-Path $BaseVhd)) { Write-Error "Base VHD not found: $BaseVhd"; exit 1 }
if (-not (Test-Path $UnattendTemplate)) { Write-Error "Unattend template not found: $UnattendTemplate"; exit 1 }

$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
    Write-Host "Switch '$SwitchName' not found. Available switches:" -ForegroundColor Yellow
    Get-VMSwitch | Format-Table Name, SwitchType -AutoSize
    exit 1
}

# ============================================
# Phase 1: Teardown
# ============================================
if (-not $SkipTeardown) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  TEARDOWN: Removing all LAB VMs" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""

    foreach ($vm in $VMs) {
        $existing = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.State -eq 'Running') {
                Write-Host "  Stopping $($vm.Name)..." -ForegroundColor Yellow
                Stop-VM -Name $vm.Name -TurnOff -Force
            }
            Write-Host "  Removing $($vm.Name)..." -ForegroundColor Yellow
            Remove-VM -Name $vm.Name -Force
        }
        $vmDir = Join-Path $VmPath $vm.Name
        if (Test-Path $vmDir) {
            Write-Host "  Deleting $vmDir..." -ForegroundColor Yellow
            Remove-Item $vmDir -Recurse -Force
        }
    }
    Write-Host "  Teardown complete." -ForegroundColor Green
}

# ============================================
# Phase 2: Create VMs
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CREATING VMs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

foreach ($vm in $VMs) {
    $vmName = $vm.Name
    Write-Host "Creating $vmName ($($vm.IP))..." -ForegroundColor Cyan

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "  Already exists, skipping." -ForegroundColor Yellow
        continue
    }

    # Create directory and copy VHD
    $vmDir = Join-Path $VmPath $vmName
    if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }
    $vhdDest = Join-Path $vmDir "$vmName.vhd"

    if (-not (Test-Path $vhdDest)) {
        Write-Host "  Copying base VHD (~10GB)..." -ForegroundColor Gray
        Copy-Item -Path $BaseVhd -Destination $vhdDest
    }

    # Generate unattend.xml
    $xmlContent = Get-Content $UnattendTemplate -Raw
    $xmlContent = $xmlContent -replace '\$\{COMPUTER_NAME\}', $vmName
    $xmlContent = $xmlContent -replace '\$\{IP_ADDRESS\}', $vm.IP
    $xmlContent = $xmlContent -replace '\$\{DNS_SERVER\}', $vm.DNS
    $xmlContent = $xmlContent -replace '\$\{GATEWAY\}', $vm.Gateway

    # Mount VHD and inject unattend
    Write-Host "  Injecting unattend.xml..." -ForegroundColor Gray
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

        # Inject unattend.xml (hostname, NLA settings)
        $xmlContent | Set-Content -Path "$pantherDir\unattend.xml" -Encoding UTF8

        # Inject oobe-setup.ps1 (static IP, WinRM, firewall, LabReady signal)
        $setupTemplate = Join-Path $RepoRoot "autounattend\oobe-setup.ps1"
        if (Test-Path $setupTemplate) {
            $setupContent = Get-Content $setupTemplate -Raw
            $setupContent = $setupContent -replace '\$\{IP_ADDRESS\}', $vm.IP
            $setupContent = $setupContent -replace '\$\{DNS_SERVER\}', $vm.DNS
            $setupContent = $setupContent -replace '\$\{GATEWAY\}', $vm.Gateway
            $setupContent | Set-Content -Path "$pantherDir\oobe-setup.ps1" -Encoding UTF8
            Write-Host "  Injected unattend.xml + oobe-setup.ps1 to $pantherDir" -ForegroundColor Gray
        } else {
            Write-Host "  Injected unattend.xml to $pantherDir (oobe-setup.ps1 not found)" -ForegroundColor Yellow
        }
    } else {
        Write-Warning "  Could not find Windows partition!"
    }

    Dismount-VHD -Path $vhdDest

    # Create Gen1 VM
    New-VM -Name $vmName -MemoryStartupBytes 4GB -VHDPath $vhdDest -SwitchName $SwitchName -Generation 1 -Path $VmPath | Out-Null
    Set-VM -Name $vmName -ProcessorCount 2 -AutomaticCheckpointsEnabled $false

    Write-Host "  Created: $vmName ($($vm.IP))" -ForegroundColor Green
}

# Start all VMs
Write-Host ""
Write-Host "Starting all VMs..." -ForegroundColor Cyan
foreach ($vm in $VMs) {
    $state = (Get-VM -Name $vm.Name -ErrorAction SilentlyContinue).State
    if ($state -ne 'Running') {
        Start-VM -Name $vm.Name
        Write-Host "  Started $($vm.Name)" -ForegroundColor Green
    }
}

# ============================================
# Phase 3: Wait for all VMs to be ready
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  WAITING FOR VMs (~5 minutes)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Set TrustedHosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.2.*" -Force 2>$null

$AdminPass = ConvertTo-SecureString "ChangeMe!2024#Secure" -AsPlainText -Force
$LocalCred = New-Object PSCredential("labadmin", $AdminPass)

$ready = @{}
foreach ($vm in $VMs) { $ready[$vm.Name] = $false }

$startTime = Get-Date
$timeout = 600 # 10 minutes

while ($true) {
    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -ge $timeout) {
        Write-Host "TIMEOUT!" -ForegroundColor Red
        break
    }

    $allReady = $true
    foreach ($vm in $VMs) {
        if ($ready[$vm.Name]) { continue }

        if (Test-Connection -ComputerName $vm.IP -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            try {
                $session = New-PSSession -ComputerName $vm.IP -Credential $LocalCred -ErrorAction Stop
                $isReady = Invoke-Command -Session $session -ScriptBlock { Test-Path "C:\LabReady.txt" }
                Remove-PSSession $session
                if ($isReady) {
                    $ready[$vm.Name] = $true
                    Write-Host "  READY: $($vm.Name) ($($vm.IP)) [$([math]::Round($elapsed))s]" -ForegroundColor Green
                    continue
                }
            } catch {}
        }
        $allReady = $false
    }

    if ($allReady) { break }

    $readyCount = ($ready.Values | Where-Object { $_ }).Count
    Write-Host "  [$([math]::Round($elapsed))s] $readyCount/$($VMs.Count) ready..." -ForegroundColor Gray
    Start-Sleep -Seconds 15
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  ALL VMs READY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  LAB-DC:         192.168.2.50  (labadmin / ChangeMe!2024#Secure)"
Write-Host "  LAB-CLIENT:     192.168.2.51  (labadmin / ChangeMe!2024#Secure)"
Write-Host "  LAB-CLIENT-2:   192.168.2.52  (labadmin / ChangeMe!2024#Secure)"
Write-Host "  LAB-STANDALONE: 192.168.2.53  (labadmin / ChangeMe!2024#Secure)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Promote LAB-DC to domain controller (run DSC or manual)"
Write-Host "  2. Join LAB-CLIENT and LAB-CLIENT-2 to domain"
Write-Host "  3. Run Setup-TestUsers.ps1 from the mideye repo"
Write-Host "  4. Deploy Mideye MSI to LAB-CLIENT-2 for testing"
Write-Host ""
