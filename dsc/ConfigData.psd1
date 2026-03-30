@{
    AllNodes = @(
        @{
            NodeName                    = '*'
            PSDscAllowPlainTextPassword = $true
            PSDscAllowDomainUser        = $true
            RebootNodeIfNeeded          = $true
        }
        @{ NodeName = 'DC';       Role = 'DomainController'; IPAddress = '192.168.2.50' }
        @{ NodeName = 'Client1';  Role = 'DomainClient';     IPAddress = '192.168.2.51' }
        @{ NodeName = 'Client2';  Role = 'DomainClient';     IPAddress = '192.168.2.52' }
        @{ NodeName = 'Local1';   Role = 'Standalone';       IPAddress = '192.168.2.53' }
    )

    # Domain settings
    DomainName    = 'lab.test'
    DomainNetBIOS = 'LAB'

    # Passwords
    AdminPassword = 'ChangeMe!2024#Secure'
    SafeModePassword = 'SafeMode!2024#Secure'
    UserPassword  = 'P@ssw0rd123'

    # Test users
    TestUsers = @(
        @{ Name = 'testuser';  FullName = 'Test User';          Mobile = '+46735120011' }
        @{ Name = 'tokenuser'; FullName = 'Token User';         Mobile = 'AI0877754540'; Pager = 'AI0877754540' }
        @{ Name = 'yubiuser';  FullName = 'YubiKey User';       Mobile = 'zmub35730633'; Pager = 'zmub35730633' }
        @{ Name = 'alus';      FullName = 'Assisted Login User'; Mobile = '+46735120011' }
        @{ Name = 'alap';      FullName = 'Assisted Approver';  Mobile = '+46724498278' }
    )
}
