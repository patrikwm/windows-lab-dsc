# oobe-setup.ps1 — runs on first logon after OOBE
# Variables ${IP_ADDRESS}, ${GATEWAY}, ${DNS_SERVER} are replaced per-VM before injection
$ErrorActionPreference = "SilentlyContinue"
Start-Transcript -Path "C:\Windows\Panther\oobe-setup.log"

Write-Host "=== Lab VM Post-OOBE Setup ==="

# 1. Network profile to Private
Write-Host "Setting network to Private..."
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# 2. Static IP
Write-Host "Configuring static IP: ${IP_ADDRESS}..."
$adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
if ($adapter) {
    $adapterName = $adapter.Name
    Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $adapterName -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $adapterName -IPAddress "${IP_ADDRESS}" -PrefixLength 24 -DefaultGateway "${GATEWAY}"
    Set-DnsClientServerAddress -InterfaceAlias $adapterName -ServerAddresses "${DNS_SERVER}","8.8.8.8"
    Write-Host "IP set on adapter: $adapterName"
} else {
    Write-Host "WARNING: No active network adapter found!"
}

# 3. Enable WinRM
Write-Host "Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
winrm quickconfig -force
winrm set winrm/config/service @{AllowUnencrypted="true"}
winrm set winrm/config/client @{TrustedHosts="*"}

# 4. Install OpenSSH Server
Write-Host "Installing OpenSSH Server..."
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd

# 5. Firewall rules
Write-Host "Configuring firewall rules..."
# RDP
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
# Ping (ICMP)
netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4:8,any dir=in action=allow
# WinRM
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow
# SSH
netsh advfirewall firewall add rule name="SSH" dir=in localport=22 protocol=TCP action=allow
# DNS (for DC)
netsh advfirewall firewall add rule name="DNS-TCP" dir=in localport=53 protocol=TCP action=allow
netsh advfirewall firewall add rule name="DNS-UDP" dir=in localport=53 protocol=UDP action=allow
# File and Printer Sharing
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"

# 6. Enable Administrator account and RDP access
Write-Host "Enabling admin RDP access..."
net user Administrator /active:yes
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "labadmin" -ErrorAction SilentlyContinue

# 7. Signal ready
Write-Host "Setup complete!"
"LabReady $(Get-Date -Format o)" | Set-Content "C:\LabReady.txt"

Stop-Transcript
