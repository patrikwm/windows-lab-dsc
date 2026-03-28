#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates 3 Hyper-V VMs with Windows Server ISO and autounattend.
.PARAMETER IsoPath
    Path to the Windows Server 2022 Evaluation ISO.
.PARAMETER VmPath
    Directory for VM files (VHDX, configs). Default: C:\fastdisk\hyper-v
.PARAMETER GitHubRepo
    GitHub repo for DSC configs. Default: patrikwm/windows-lab-dsc
.PARAMETER GitHubBranch
    Branch to pull DSC from. Default: main
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [string]$VmPath = "C:\fastdisk\hyper-v",
    [string]$GitHubRepo = "patrikwm/windows-lab-dsc",
    [string]$GitHubBranch = "main"
)

$ErrorActionPreference = "Stop"
$SwitchName = "WinLab"

if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found: $IsoPath"
    exit 1
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Error "Switch '$SwitchName' not found. Run 01-Create-LabNetwork.ps1 first."
    exit 1
}

# VM definitions
$VMs = @(
    @{ Name = "LAB-DC";         IP = "10.0.0.10"; DNS = "8.8.8.8";   Role = "DC" }
    @{ Name = "LAB-CLIENT";     IP = "10.0.0.20"; DNS = "10.0.0.10"; Role = "Client" }
    @{ Name = "LAB-STANDALONE"; IP = "10.0.0.30"; DNS = "8.8.8.8";   Role = "Standalone" }
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$AutounattendDir = Join-Path $RepoRoot "autounattend"

# Function to create a small ISO from a directory using IMAPI2
function New-AutounattendIso {
    param([string]$SourceDir, [string]$OutputIso)

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 2  # FsiFileSystemISO9660
    $fsi.VolumeName = "AUTOUNATTEND"

    $sourceDir = Get-Item $SourceDir
    foreach ($file in (Get-ChildItem $SourceDir)) {
        $stream = New-Object -ComObject ADODB.Stream
        $stream.Open()
        $stream.Type = 1  # Binary
        $stream.LoadFromFile($file.FullName)
        $fsi.Root.AddFile($file.Name, $stream)
    }

    $result = $fsi.CreateResultImage()
    $resultStream = $result.ImageStream

    $outStream = [System.IO.File]::Create($OutputIso)
    $buffer = New-Object byte[] 2048
    while ($true) {
        $bytesRead = $resultStream.Read($buffer, 0, $buffer.Length)
        if ($bytesRead -eq 0) { break }
        $outStream.Write($buffer, 0, $bytesRead)
    }
    $outStream.Close()
}

foreach ($vm in $VMs) {
    $vmName = $vm.Name
    Write-Host "Creating VM: $vmName..." -ForegroundColor Cyan

    # Skip if already exists
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "  VM '$vmName' already exists, skipping." -ForegroundColor Yellow
        continue
    }

    # Create VHDX
    $vmDir = Join-Path $VmPath $vmName
    $vhdxPath = Join-Path $vmDir "$vmName.vhdx"
    if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }
    if (-not (Test-Path $vhdxPath)) {
        New-VHD -Path $vhdxPath -SizeBytes 60GB -Dynamic | Out-Null
    }

    # Create VM
    New-VM -Name $vmName `
        -MemoryStartupBytes 4GB `
        -VHDPath $vhdxPath `
        -SwitchName $SwitchName `
        -Generation 2 `
        -Path $VmPath | Out-Null

    Set-VM -Name $vmName -ProcessorCount 2 -AutomaticCheckpointsEnabled $false

    # Attach Windows ISO
    Add-VMDvdDrive -VMName $vmName
    $dvdDrives = Get-VMDvdDrive -VMName $vmName
    Set-VMDvdDrive -VMName $vmName -ControllerNumber $dvdDrives[0].ControllerNumber `
        -ControllerLocation $dvdDrives[0].ControllerLocation -Path $IsoPath

    # Set firmware: Secure Boot with Microsoft Windows template, boot from DVD
    Set-VMFirmware -VMName $vmName -SecureBootTemplate MicrosoftWindows
    $dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1
    $hdd = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
    Set-VMFirmware -VMName $vmName -BootOrder $dvd, $hdd

    # Prepare autounattend XML with variable substitution
    $role = $vm.Role.ToLower()
    $templatePath = Join-Path $AutounattendDir "$role.xml"
    if (-not (Test-Path $templatePath)) {
        Write-Error "Autounattend template not found: $templatePath"
        exit 1
    }

    $xmlContent = Get-Content $templatePath -Raw
    $xmlContent = $xmlContent -replace '\$\{COMPUTER_NAME\}', $vmName
    $xmlContent = $xmlContent -replace '\$\{IP_ADDRESS\}', $vm.IP
    $xmlContent = $xmlContent -replace '\$\{DNS_SERVER\}', $vm.DNS
    $xmlContent = $xmlContent -replace '\$\{GITHUB_REPO\}', $GitHubRepo
    $xmlContent = $xmlContent -replace '\$\{GITHUB_BRANCH\}', $GitHubBranch
    $xmlContent = $xmlContent -replace '\$\{VM_ROLE\}', $vm.Role

    # Create autounattend ISO
    $tempDir = Join-Path $env:TEMP "autounattend-$vmName"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $xmlContent | Set-Content -Path (Join-Path $tempDir "autounattend.xml") -Encoding UTF8

    $auIsoPath = Join-Path $vmDir "autounattend.iso"
    New-AutounattendIso -SourceDir $tempDir -OutputIso $auIsoPath
    Remove-Item $tempDir -Recurse -Force

    # Attach autounattend ISO as second DVD
    Add-VMDvdDrive -VMName $vmName -Path $auIsoPath

    Write-Host "  Created: $vmName ($($vm.IP), $($vm.Role))" -ForegroundColor Green
}

# Start all VMs
Write-Host ""
Write-Host "Starting all VMs..." -ForegroundColor Cyan
foreach ($vm in $VMs) {
    $state = (Get-VM -Name $vm.Name).State
    if ($state -ne 'Running') {
        Start-VM -Name $vm.Name
        Write-Host "  Started $($vm.Name)" -ForegroundColor Green
    } else {
        Write-Host "  $($vm.Name) already running" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "All VMs created and started." -ForegroundColor Green
Write-Host "Windows will install automatically from the ISO + autounattend."
Write-Host "Run 03-Wait-ForInstall.ps1 to wait until all VMs are ready."
