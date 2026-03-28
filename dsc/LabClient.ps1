Configuration LabClient {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationData
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName ComputerManagementDsc
    Import-DscResource -ModuleName NetworkingDsc

    $configData = Import-PowerShellDataFile $ConfigurationData
    $domainName = $configData.DomainName
    $domainNetBIOS = $configData.DomainNetBIOS
    $adminPw = ConvertTo-SecureString $configData.AdminPassword -AsPlainText -Force
    $domainCred = New-Object PSCredential("$domainNetBIOS\labadmin", $adminPw)

    Node localhost {

        # Join domain
        Computer JoinDomain {
            Name       = $env:COMPUTERNAME
            DomainName = $domainName
            Credential = $domainCred
        }

        # Add Domain Users to Remote Desktop Users (after domain join)
        Group RDPUsers {
            GroupName        = 'Remote Desktop Users'
            MembersToInclude = @("$domainNetBIOS\Domain Users")
            Ensure           = 'Present'
            DependsOn        = '[Computer]JoinDomain'
        }

        # Enable RDP
        Registry EnableRDP {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
            ValueName = 'fDenyTSConnections'
            ValueData = '0'
            ValueType = 'DWord'
            Ensure    = 'Present'
        }

        # Disable NLA — allows custom credential providers to intercept before NLA
        Registry DisableNLA {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
            ValueName = 'UserAuthentication'
            ValueData = '0'
            ValueType = 'DWord'
            Ensure    = 'Present'
        }

        # Firewall rules
        Firewall AllowRDP {
            Name        = 'AllowRDP-Lab'
            DisplayName = 'Allow RDP (Lab)'
            Action      = 'Allow'
            Direction   = 'Inbound'
            LocalPort   = '3389'
            Protocol    = 'TCP'
            Ensure      = 'Present'
        }

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
