<#
.SYNOPSIS
    Promotes LAB-DC to domain controller and joins client VMs to the domain.
.DESCRIPTION
    Phase 1: Promote LAB-DC to DC (installs AD DS, DNS, GPMC, creates forest)
    Phase 2: Wait for DC reboot
    Phase 3: Create test users in AD with phone/token attributes
    Phase 4: Join LAB-CLIENT and LAB-CLIENT-2 to the domain
    Phase 5: Configure RDP settings on all client VMs

    Run this AFTER 05-Rebuild-Lab.ps1 has completed.
.PARAMETER DcIp
    LAB-DC IP address. Default: 192.168.2.50
.PARAMETER DomainName
    Domain name. Default: lab.test
.PARAMETER DomainNetBIOS
    NetBIOS name. Default: LAB
#>
param(
    [string]$DcIp = "192.168.2.50",
    [string]$DomainName = "lab.test",
    [string]$DomainNetBIOS = "LAB"
)

$ErrorActionPreference = "Stop"

$AdminPassword = "ChangeMe!2024#Secure"
$SafeModePassword = "SafeMode!2024#Secure"
$UserPassword = "P@ssw0rd123"

$secAdminPass = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
$localCred = New-Object PSCredential("labadmin", $secAdminPass)

$ClientVMs = @(
    @{ Name = "LAB-CLIENT";   IP = "192.168.2.51" }
    @{ Name = "LAB-CLIENT-2"; IP = "192.168.2.52" }
)

# ============================================
# Phase 1: Promote LAB-DC
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Phase 1: Promote LAB-DC to DC" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$dcSession = New-PSSession -ComputerName $DcIp -Credential $localCred

Invoke-Command -Session $dcSession -ScriptBlock {
    param($DomainName, $DomainNetBIOS, $SafeModePassword)

    # Check if already a DC
    $adFeature = Get-WindowsFeature AD-Domain-Services
    if ($adFeature.Installed) {
        $dcCheck = Get-ADDomainController -ErrorAction SilentlyContinue
        if ($dcCheck) {
            Write-Host "  Already a domain controller for $($dcCheck.Domain)" -ForegroundColor Green
            return
        }
    }

    Write-Host "  Installing AD DS + DNS + GPMC..."
    Install-WindowsFeature -Name AD-Domain-Services, DNS, GPMC -IncludeManagementTools | Out-Null
    Write-Host "  Features installed." -ForegroundColor Green

    Write-Host "  Promoting to Domain Controller (this will reboot)..."
    $safePw = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force

    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $DomainNetBIOS `
        -SafeModeAdministratorPassword $safePw `
        -InstallDns:$true `
        -NoRebootOnCompletion:$false `
        -Force:$true

} -ArgumentList $DomainName, $DomainNetBIOS, $SafeModePassword

Remove-PSSession $dcSession -ErrorAction SilentlyContinue

# ============================================
# Phase 2: Wait for DC to come back
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Phase 2: Waiting for DC to reboot (~3 min)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Start-Sleep -Seconds 30

$domainCred = New-Object PSCredential("$DomainNetBIOS\labadmin", $secAdminPass)
$dcReady = $false
$attempts = 0

while (-not $dcReady -and $attempts -lt 30) {
    $attempts++
    Start-Sleep -Seconds 10
    try {
        $dcSession = New-PSSession -ComputerName $DcIp -Credential $domainCred -ErrorAction Stop
        $dcReady = Invoke-Command -Session $dcSession -ScriptBlock {
            try { Get-ADDomain -ErrorAction Stop; return $true } catch { return $false }
        }
        if ($dcReady) {
            Write-Host "  DC is ready! [$($attempts * 10)s]" -ForegroundColor Green
        }
        Remove-PSSession $dcSession -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  Waiting... [$($attempts * 10)s]" -ForegroundColor Gray
    }
}

if (-not $dcReady) {
    Write-Error "DC did not come back in time. Check manually."
    exit 1
}

# ============================================
# Phase 3: Create test users in AD
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Phase 3: Creating AD test users" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$dcSession = New-PSSession -ComputerName $DcIp -Credential $domainCred

Invoke-Command -Session $dcSession -ScriptBlock {
    param($UserPassword)

    $pw = ConvertTo-SecureString $UserPassword -AsPlainText -Force

    $users = @(
        @{ Name = "testuser";    FullName = "Test User";       Mobile = "+46735120011"; Pager = "" }
        @{ Name = "tokenuser";   FullName = "Token User";      Mobile = "AI0877754540"; Pager = "AI0877754540" }
        @{ Name = "yubiuser";    FullName = "YubiKey User";    Mobile = "zmub35730633"; Pager = "zmub35730633" }
        @{ Name = "alus";        FullName = "Assisted User";   Mobile = "+46735120011"; Pager = "" }
        @{ Name = "alap";        FullName = "Assisted Approver"; Mobile = "+46724498278"; Pager = "" }
    )

    foreach ($u in $users) {
        $existing = Get-ADUser -Filter "SamAccountName -eq '$($u.Name)'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $($u.Name) already exists, updating attributes..."
        } else {
            New-ADUser -Name $u.FullName -SamAccountName $u.Name `
                -UserPrincipalName "$($u.Name)@lab.test" `
                -AccountPassword $pw -Enabled $true `
                -PasswordNeverExpires $true -ChangePasswordAtLogon $false
            Write-Host "  Created: $($u.Name)"
        }

        # Set phone/token attributes
        $attrs = @{}
        if ($u.Mobile) { $attrs['mobile'] = $u.Mobile }
        if ($u.Pager) { $attrs['pager'] = $u.Pager }
        if ($attrs.Count -gt 0) {
            Set-ADUser -Identity $u.Name -Replace $attrs
        }

        # Add to Remote Desktop Users
        Add-ADGroupMember -Identity "Remote Desktop Users" -Members $u.Name -ErrorAction SilentlyContinue
    }

    # Configure DNS forwarder for internet
    Add-DnsServerForwarder -IPAddress "8.8.8.8" -ErrorAction SilentlyContinue
    Add-DnsServerForwarder -IPAddress "8.8.4.4" -ErrorAction SilentlyContinue
    Write-Host "  DNS forwarders configured" -ForegroundColor Green

} -ArgumentList $UserPassword

Remove-PSSession $dcSession

# ============================================
# Phase 4: Join client VMs to domain
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Phase 4: Joining clients to domain" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

foreach ($client in $ClientVMs) {
    Write-Host "  Joining $($client.Name) ($($client.IP))..." -ForegroundColor Cyan
    try {
        $session = New-PSSession -ComputerName $client.IP -Credential $localCred -ErrorAction Stop

        Invoke-Command -Session $session -ScriptBlock {
            param($DcIp, $DomainName, $AdminPassword, $DomainNetBIOS)

            # Set DNS to DC first
            $adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DcIp, "8.8.8.8"
            Write-Host "    DNS set to $DcIp"

            # Check if already joined
            $cs = Get-CimInstance Win32_ComputerSystem
            if ($cs.PartOfDomain -and $cs.Domain -eq $DomainName) {
                Write-Host "    Already joined to $DomainName" -ForegroundColor Green
                return
            }

            # Join domain
            $domainPass = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
            $domainCred = New-Object PSCredential("$DomainNetBIOS\labadmin", $domainPass)
            Add-Computer -DomainName $DomainName -Credential $domainCred -Force
            Write-Host "    Joined to $DomainName (reboot needed)"

        } -ArgumentList $DcIp, $DomainName, $AdminPassword, $DomainNetBIOS

        # Add Domain Users to Remote Desktop Users
        Invoke-Command -Session $session -ScriptBlock {
            param($DomainNetBIOS)
            net localgroup "Remote Desktop Users" "$DomainNetBIOS\Domain Users" /add 2>$null
        } -ArgumentList $DomainNetBIOS

        Remove-PSSession $session
    } catch {
        Write-Host "    FAILED: $_" -ForegroundColor Red
    }
}

# ============================================
# Phase 5: Configure RDP settings + Reboot clients
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Phase 5: Configure RDP + Reboot" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

foreach ($client in $ClientVMs) {
    try {
        $session = New-PSSession -ComputerName $client.IP -Credential $localCred -ErrorAction Stop

        Invoke-Command -Session $session -ScriptBlock {
            $rdpPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
            Set-ItemProperty -Path $rdpPath -Name "UserAuthentication" -Value 0
            Set-ItemProperty -Path $rdpPath -Name "SecurityLayer" -Value 2
            Set-ItemProperty -Path $rdpPath -Name "fDisableEncryption" -Value 0
            Set-ItemProperty -Path $rdpPath -Name "fPromptForPassword" -Value 1
            Write-Host "    RDP configured: NLA=0, SecurityLayer=2"
        }

        Invoke-Command -Session $session -ScriptBlock { Restart-Computer -Force }
        Remove-PSSession $session
        Write-Host "  $($client.Name) rebooting..." -ForegroundColor Green
    } catch {
        Write-Host "  $($client.Name) FAILED: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  DOMAIN SETUP COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Domain:     $DomainName ($DomainNetBIOS)"
Write-Host "  DC:         $DcIp"
Write-Host "  Clients:    192.168.2.51, 192.168.2.52 (rebooting)"
Write-Host ""
Write-Host "  AD Users:"
Write-Host "    testuser    - Touch MFA (+46735120011)"
Write-Host "    tokenuser   - HiD Token (AI0877754540)"
Write-Host "    yubiuser    - YubiKey (zmub35730633)"
Write-Host "    alus        - Assisted Login (+46735120011)"
Write-Host "    alap        - Approver (+46724498278)"
Write-Host ""
Write-Host "  All user passwords: $UserPassword"
Write-Host "  Admin password: $AdminPassword"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Wait ~1 min for client reboots"
Write-Host "  2. Deploy Mideye MSI to LAB-CLIENT-2 (192.168.2.52)"
Write-Host "  3. Run Setup-TestUsers.ps1 for local user + registry config"
Write-Host ""
