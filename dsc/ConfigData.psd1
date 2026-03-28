@{
    AllNodes = @(
        @{
            NodeName                    = '*'
            PSDscAllowPlainTextPassword = $true
            PSDscAllowDomainUser        = $true
            RebootNodeIfNeeded          = $true
        }
        @{ NodeName = 'DC';         Role = 'DomainController'; IPAddress = '10.0.0.10' }
        @{ NodeName = 'Client';     Role = 'DomainClient';     IPAddress = '10.0.0.20' }
        @{ NodeName = 'Standalone'; Role = 'Standalone';       IPAddress = '10.0.0.30' }
    )

    # Domain settings
    DomainName    = 'lab.test'
    DomainNetBIOS = 'LAB'

    # Passwords
    AdminPassword = 'ChangeMe!2024#Secure'
    SafeModePassword = 'SafeMode!2024#Secure'
    UserPassword  = 'P@ssw0rd123'

    # Test users — placeholder phone numbers (override in private configure-lab.ps1)
    TestUsers = @(
        @{ Name = 'testuser';     FullName = 'Test User';      Mobile = '+15551234567' }
        @{ Name = 'tokenuser';    FullName = 'Token User';     Mobile = 'ubbc06434510'; Pager = 'AI0877754540' }
        @{ Name = 'assisteduser'; FullName = 'Assisted User';  Mobile = '+15559876543' }
        @{ Name = 'nofactoruser'; FullName = 'No Factor User' }
    )
}
