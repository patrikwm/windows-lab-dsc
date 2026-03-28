<#
.SYNOPSIS
    Bootstrap script run by autounattend FirstLogonCommands.
    Downloads DSC config from GitHub and applies it.
.PARAMETER Role
    VM role: DC, Client, or Standalone
.PARAMETER GitHubRepo
    GitHub repo (org/name format)
.PARAMETER GitHubBranch
    Branch to pull from
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet("DC", "Client", "Standalone")]
    [string]$Role,

    [string]$GitHubRepo = "patrikwm/windows-lab-dsc",
    [string]$GitHubBranch = "main"
)

$ErrorActionPreference = "Stop"
$DscDir = "C:\DSC"
$LogFile = "C:\DSC\bootstrap.log"

function Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

$BaseUrl = "https://raw.githubusercontent.com/$GitHubRepo/$GitHubBranch"

try {
    Log "Bootstrap starting for role: $Role"
    Log "Pulling DSC from: $BaseUrl"

    # Ensure TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Install NuGet provider and trust PSGallery
    Log "Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    # Install required DSC modules
    $modules = @(
        'ActiveDirectoryDsc',
        'ComputerManagementDsc',
        'NetworkingDsc',
        'DnsServerDsc'
    )

    foreach ($mod in $modules) {
        Log "Installing DSC module: $mod"
        Install-Module -Name $mod -Force -AllowClobber | Out-Null
    }

    # Download DSC config files
    $files = @(
        "dsc/ConfigData.psd1",
        "dsc/Lab$Role.ps1"
    )

    foreach ($file in $files) {
        $url = "$BaseUrl/$file"
        $dest = Join-Path $DscDir (Split-Path $file -Leaf)
        Log "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    }

    # For Client role: wait until DC is reachable (domain DNS must work)
    if ($Role -eq "Client") {
        Log "Waiting for domain controller DNS (lab.test)..."
        $maxWait = 30  # minutes
        $waited = 0
        while ($waited -lt ($maxWait * 60)) {
            try {
                $result = Resolve-DnsName "lab.test" -ErrorAction Stop
                if ($result) {
                    Log "DC DNS is ready: lab.test resolved"
                    break
                }
            } catch {}
            Start-Sleep -Seconds 30
            $waited += 30
            Log "  Still waiting for DC DNS... ($([math]::Round($waited/60,1))m)"
        }
        if ($waited -ge ($maxWait * 60)) {
            Log "WARNING: Timed out waiting for DC DNS. Proceeding anyway."
        }
    }

    # Configure LCM for reboots
    Log "Configuring Local Configuration Manager..."
    [DSCLocalConfigurationManager()]
    Configuration LCMConfig {
        Node localhost {
            Settings {
                RebootNodeIfNeeded = $true
                ActionAfterReboot  = 'ContinueConfiguration'
                ConfigurationMode  = 'ApplyOnly'
            }
        }
    }
    LCMConfig -OutputPath "$DscDir\LCM" | Out-Null
    Set-DscLocalConfigurationManager -Path "$DscDir\LCM" -Force

    # Compile DSC configuration
    $configScript = Join-Path $DscDir "Lab$Role.ps1"
    $configData = Join-Path $DscDir "ConfigData.psd1"
    $mofDir = Join-Path $DscDir "MOF"

    Log "Compiling DSC configuration: Lab$Role"
    . $configScript
    $configName = "Lab$Role"
    & $configName -ConfigurationData $configData -OutputPath $mofDir | Out-Null

    # Apply DSC
    Log "Applying DSC configuration..."
    Start-DscConfiguration -Path $mofDir -Wait -Verbose -Force *>> $LogFile

    Log "DSC configuration applied successfully."

    # Create sentinel file
    "DSC bootstrap complete at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content "C:\LabReady.txt"
    Log "LabReady.txt created. Bootstrap complete."

} catch {
    Log "BOOTSTRAP ERROR: $_"
    Log $_.ScriptStackTrace
    # Create error sentinel so wait script can detect the failure
    "FAILED: $_ at $(Get-Date)" | Set-Content "C:\LabFailed.txt"
    exit 1
}
