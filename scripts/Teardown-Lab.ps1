#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the entire lab: VMs, disks, network.
#>

$ErrorActionPreference = "SilentlyContinue"
$VmPath = "C:\fastdisk\hyper-v"

Write-Host "Tearing down lab..." -ForegroundColor Yellow

foreach ($vmName in @("LAB-DC", "LAB-CLIENT-1", "LAB-CLIENT-2", "LAB-LOCAL-1")) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        if ($vm.State -eq 'Running') {
            Stop-VM -Name $vmName -TurnOff -Force
            Write-Host "  Stopped $vmName" -ForegroundColor Gray
        }
        Remove-VM -Name $vmName -Force
        Write-Host "  Removed $vmName" -ForegroundColor Gray
    }
    $vmDir = Join-Path $VmPath $vmName
    if (Test-Path $vmDir) {
        Remove-Item $vmDir -Recurse -Force
        Write-Host "  Deleted $vmDir" -ForegroundColor Gray
    }
}

Remove-NetNat -Name "WinLabNAT" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "  Removed NAT" -ForegroundColor Gray

Remove-VMSwitch -Name "WinLab" -Force -ErrorAction SilentlyContinue
Write-Host "  Removed switch" -ForegroundColor Gray

Write-Host ""
Write-Host "Lab removed." -ForegroundColor Green
