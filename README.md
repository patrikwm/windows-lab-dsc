# Windows Lab DSC

Automated Hyper-V lab with 4 Windows Server 2022 VMs for testing the Mideye Credential Provider. Designed to be torn down and rebuilt repeatedly during development.

## What you get

| VM | Role | IP | Description |
|----|------|----|-------------|
| LAB-DC | Domain Controller | 192.168.2.50 | AD DS + DNS + GPMC, test users with AD attributes |
| LAB-CLIENT-1 | Domain-joined | 192.168.2.51 | Production reference (DO NOT deploy untested changes) |
| LAB-CLIENT-2 | Domain-joined | 192.168.2.52 | Dev/test machine for Mideye deployment |
| LAB-LOCAL-1 | Standalone | 192.168.2.53 | Local users, registry-based config, no domain |

All VMs: Windows Server 2022, 4GB RAM, 2 vCPU, labadmin / ChangeMe!2024#Secure

## Prerequisites

- Windows 10/11 Pro or Enterprise with Hyper-V enabled
- ~20GB free RAM (16GB for VMs + host)
- ~50GB free disk
- Windows Server 2022 Evaluation VHD ([download](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022))
- An External Hyper-V switch (named "External-LAN" or any name)

## Quick start

```powershell
# Run all commands as Administrator

# 1. Create the VMs (provide path to base VHD)
.\scripts\02-Create-VMs.ps1 -VhdPath "C:\fastdisk\hyper-v\iso\windows-server-2022-eval.vhd"

# 2. Wait for OOBE to complete (~5 minutes)
.\scripts\03-Wait-ForInstall.ps1

# 3. Promote DC + create AD users + join clients to domain
.\scripts\04-Setup-Domain.ps1
```

That's it. Four VMs running, domain configured, test users created, RDP ready.

## Test users

| User | Password | AD mobile | AD pager | Purpose |
|------|----------|-----------|----------|---------|
| testuser | P@ssw0rd123 | +46735120011 | - | Touch MFA (phone push) |
| tokenuser | P@ssw0rd123 | AI0877754540 | AI0877754540 | HiD hardware token |
| yubiuser | P@ssw0rd123 | zmub35730633 | zmub35730633 | YubiKey OTP |
| alus | P@ssw0rd123 | +46735120011 | - | Assisted Login (needs approval) |
| alap | P@ssw0rd123 | +46724498278 | - | Assisted Login Approver |

Admin: `labadmin` / `ChangeMe!2024#Secure`

## Teardown

```powershell
.\scripts\Teardown-Lab.ps1
```

## Deploying Mideye

After the lab is up, deploy Mideye to LAB-CLIENT-2 (the test machine):

```powershell
cd ..\mideye-rdp-credential-provider

# Set up test users (from .env)
.\infra\Setup-TestUsers.ps1

# Or install via MSI on the server
# Copy MSI to server, double-click, reboot
```

See `mideye-rdp-credential-provider/docs/INTEGRATION-GUIDE.md` for the full setup.

## Network

```
  LAB-DC        LAB-CLIENT-1   LAB-CLIENT-2   LAB-LOCAL-1
  .2.50         .2.51          .2.52          .2.53
    |               |              |              |
    +---------------+--------------+--------------+
              External Hyper-V Switch
                      |
                 Physical NIC
              192.168.2.0/24
```
