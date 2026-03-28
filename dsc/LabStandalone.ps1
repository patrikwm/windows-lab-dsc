Configuration LabStandalone {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationData
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName NetworkingDsc

    $configData = Import-PowerShellDataFile $ConfigurationData
    $userPw = ConvertTo-SecureString $configData.UserPassword -AsPlainText -Force

    Node localhost {

        # Create local test users
        foreach ($user in $configData.TestUsers) {
            $userName = $user.Name
            User "User_$userName" {
                UserName             = $userName
                FullName             = $user.FullName
                Password             = New-Object PSCredential($userName, $userPw)
                PasswordNeverExpires = $true
                Ensure               = 'Present'
                Disabled             = $false
            }

            Group "RDP_$userName" {
                GroupName        = 'Remote Desktop Users'
                MembersToInclude = @($userName)
                Ensure           = 'Present'
                DependsOn        = "[User]User_$userName"
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

        # Disable NLA
        Registry DisableNLA {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
            ValueName = 'UserAuthentication'
            ValueData = '0'
            ValueType = 'DWord'
            Ensure    = 'Present'
        }

        # Firewall
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
