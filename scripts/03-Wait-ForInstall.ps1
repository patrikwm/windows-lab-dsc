#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Waits until all 3 lab VMs have completed OS install and DSC configuration.
.DESCRIPTION
    Polls each VM every 30 seconds via WinRM until C:\LabReady.txt exists,
    indicating the autounattend + DSC bootstrap completed successfully.
#>

$ErrorActionPreference = "Stop"

$VMs = @(
    @{ Name = "LAB-DC";         IP = "10.0.0.10" }
    @{ Name = "LAB-CLIENT";     IP = "10.0.0.20" }
    @{ Name = "LAB-STANDALONE"; IP = "10.0.0.30" }
)

$AdminUser = "labadmin"
$AdminPass = ConvertTo-SecureString "ChangeMe!2024#Secure" -AsPlainText -Force
$LocalCred = New-Object PSCredential($AdminUser, $AdminPass)
$DomainCred = New-Object PSCredential("LAB\$AdminUser", $AdminPass)

$TimeoutMinutes = 45
$PollIntervalSeconds = 30

Write-Host "Waiting for all VMs to complete setup..." -ForegroundColor Cyan
Write-Host "Timeout: $TimeoutMinutes minutes. Polling every $PollIntervalSeconds seconds."
Write-Host ""

$startTime = Get-Date
$ready = @{}
foreach ($vm in $VMs) { $ready[$vm.Name] = $false }

while ($true) {
    $elapsed = (Get-Date) - $startTime
    if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
        Write-Host ""
        Write-Host "TIMEOUT after $TimeoutMinutes minutes!" -ForegroundColor Red
        foreach ($vm in $VMs) {
            if (-not $ready[$vm.Name]) {
                Write-Host "  NOT READY: $($vm.Name) ($($vm.IP))" -ForegroundColor Red
            }
        }
        exit 1
    }

    $allReady = $true
    foreach ($vm in $VMs) {
        if ($ready[$vm.Name]) { continue }

        $ip = $vm.IP
        $name = $vm.Name

        # Try ping first
        if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
            $allReady = $false
            continue
        }

        # Try WinRM with local cred, then domain cred (DC changes after promotion)
        $isReady = $false
        foreach ($cred in @($LocalCred, $DomainCred)) {
            try {
                $result = Invoke-Command -ComputerName $ip -Credential $cred -ScriptBlock {
                    Test-Path "C:\LabReady.txt"
                } -ErrorAction Stop
                if ($result -eq $true) {
                    $isReady = $true
                    break
                }
            } catch {
                # WinRM not ready yet or wrong credential, try next
            }
        }

        if ($isReady) {
            $ready[$name] = $true
            Write-Host "  READY: $name ($ip) [$([math]::Round($elapsed.TotalMinutes,1))m]" -ForegroundColor Green
        } else {
            $allReady = $false
        }
    }

    if ($allReady) { break }

    # Status line
    $readyCount = ($ready.Values | Where-Object { $_ }).Count
    $elapsedStr = "{0:mm\:ss}" -f $elapsed
    Write-Host "  [$elapsedStr] $readyCount/3 VMs ready..." -ForegroundColor Gray
    Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Host ""
Write-Host "All VMs ready!" -ForegroundColor Green

# Eject DVD drives
Write-Host "Ejecting installation media..." -ForegroundColor Cyan
foreach ($vm in $VMs) {
    Get-VMDvdDrive -VMName $vm.Name | ForEach-Object {
        Set-VMDvdDrive -VMName $vm.Name -ControllerNumber $_.ControllerNumber -ControllerLocation $_.ControllerLocation -Path $null
    }
}

Write-Host ""
Write-Host "Lab is fully operational:" -ForegroundColor Green
Write-Host "  DC:         mstsc /v:10.0.0.10  (LAB\labadmin)"
Write-Host "  Client:     mstsc /v:10.0.0.20  (LAB\testuser or LAB\labadmin)"
Write-Host "  Standalone: mstsc /v:10.0.0.30  (labadmin)"
