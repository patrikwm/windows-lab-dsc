Configuration LabDC {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationData
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName ActiveDirectoryDsc
    Import-DscResource -ModuleName DnsServerDsc
    Import-DscResource -ModuleName NetworkingDsc

    $configData = Import-PowerShellDataFile $ConfigurationData
    $domainName = $configData.DomainName
    $domainNetBIOS = $configData.DomainNetBIOS
    $adminPw = ConvertTo-SecureString $configData.AdminPassword -AsPlainText -Force
    $safePw = ConvertTo-SecureString $configData.SafeModePassword -AsPlainText -Force
    $userPw = ConvertTo-SecureString $configData.UserPassword -AsPlainText -Force
    $adminCred = New-Object PSCredential("$domainNetBIOS\labadmin", $adminPw)
    $safeCred = New-Object PSCredential("SafeMode", $safePw)

    Node localhost {

        # Install AD DS
        WindowsFeature ADDS {
            Name   = 'AD-Domain-Services'
            Ensure = 'Present'
        }

        WindowsFeature ADDSTools {
            Name      = 'RSAT-ADDS'
            Ensure    = 'Present'
            DependsOn = '[WindowsFeature]ADDS'
        }

        WindowsFeature DNS {
            Name   = 'DNS'
            Ensure = 'Present'
        }

        WindowsFeature DNSTools {
            Name      = 'RSAT-DNS-Server'
            Ensure    = 'Present'
            DependsOn = '[WindowsFeature]DNS'
        }

        # Promote to Domain Controller
        ADDomain LabDomain {
            DomainName                    = $domainName
            DomainNetbiosName             = $domainNetBIOS
            SafemodeAdministratorPassword = $safeCred
            Credential                    = $adminCred
            ForestMode                    = 'WinThreshold'
            DomainMode                    = 'WinThreshold'
            DependsOn                     = @('[WindowsFeature]ADDS', '[WindowsFeature]DNS')
        }

        # Wait for domain to be available
        WaitForADDomain WaitForDomain {
            DomainName = $domainName
            DependsOn  = '[ADDomain]LabDomain'
        }

        # DNS forwarder for internet access
        DnsServerForwarder GoogleDNS {
            IsSingleInstance = 'Yes'
            IPAddresses      = @('8.8.8.8', '8.8.4.4')
            DependsOn        = '[WaitForADDomain]WaitForDomain'
        }

        # Create test users
        foreach ($user in $configData.TestUsers) {
            $userName = $user.Name
            ADUser "User_$userName" {
                DomainName  = $domainName
                UserName    = $userName
                UserPrincipalName = "$userName@$domainName"
                DisplayName = $user.FullName
                GivenName   = ($user.FullName -split ' ')[0]
                Surname     = ($user.FullName -split ' ')[-1]
                Password    = New-Object PSCredential($userName, $userPw)
                PasswordNeverExpires = $true
                Ensure      = 'Present'
                Enabled     = $true
                DependsOn   = '[WaitForADDomain]WaitForDomain'
                Credential  = $adminCred
            }

            # Add to Remote Desktop Users
            ADGroup "RDP_$userName" {
                GroupName        = 'Remote Desktop Users'
                GroupScope       = 'DomainLocal'
                MembersToInclude = @($userName)
                Ensure           = 'Present'
                DependsOn        = "[ADUser]User_$userName"
                Credential       = $adminCred
            }
        }

        # Set AD attributes (mobile, pager) — DSC ADUser doesn't support OtherAttributes directly
        # Use a Script resource as a workaround
        foreach ($user in $configData.TestUsers) {
            $userName = $user.Name
            if ($user.Mobile -or $user.Pager) {
                Script "SetAttributes_$userName" {
                    GetScript = { return @{ Result = "OK" } }
                    TestScript = {
                        $u = Get-ADUser -Identity $using:userName -Properties mobile, pager -ErrorAction SilentlyContinue
                        if (-not $u) { return $false }
                        $mobileMatch = if ($using:user.Mobile) { $u.mobile -eq $using:user.Mobile } else { $true }
                        $pagerMatch = if ($using:user.Pager) { $u.pager -eq $using:user.Pager } else { $true }
                        return ($mobileMatch -and $pagerMatch)
                    }
                    SetScript = {
                        $attrs = @{}
                        if ($using:user.Mobile) { $attrs['mobile'] = $using:user.Mobile }
                        if ($using:user.Pager) { $attrs['pager'] = $using:user.Pager }
                        Set-ADUser -Identity $using:userName -Replace $attrs
                    }
                    DependsOn = "[ADUser]User_$userName"
                }
            }
        }

        # Enable RDP
        Registry EnableRDP {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
            ValueName = 'fDenyTSConnections'
            ValueData = '0'
            ValueType = 'DWord'
            Ensure    = 'Present'
        }

        # Open RDP firewall
        Firewall AllowRDP {
            Name        = 'AllowRDP-Lab'
            DisplayName = 'Allow RDP (Lab)'
            Action      = 'Allow'
            Direction   = 'Inbound'
            LocalPort   = '3389'
            Protocol    = 'TCP'
            Ensure      = 'Present'
        }

        # Open WinRM firewall
        Firewall AllowWinRM {
            Name        = 'AllowWinRM-Lab'
            DisplayName = 'Allow WinRM (Lab)'
            Action      = 'Allow'
            Direction   = 'Inbound'
            LocalPort   = '5985'
            Protocol    = 'TCP'
            Ensure      = 'Present'
        }
    }
}
