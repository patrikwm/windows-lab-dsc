# Windows Lab DSC

Automated Hyper-V lab with 3 Windows Server 2022 VMs configured via PowerShell Desired State Configuration (DSC). Designed for testing Windows Credential Providers, MFA solutions, and Active Directory integration.

## What you get

| VM | Role | IP | Description |
|----|------|----|-------------|
| LAB-DC | Domain Controller | 10.0.0.10 | AD DS + DNS, test users with AD attributes |
| LAB-CLIENT | Domain-joined | 10.0.0.20 | RDP-enabled, NLA disabled, credential provider ready |
| LAB-STANDALONE | Workgroup | 10.0.0.30 | Local users, registry-based config, OT simulation |

All VMs: Windows Server 2022 Desktop Experience, 4GB RAM, 2 vCPU, 60GB disk.

## Prerequisites

- Windows 10/11 Pro or Enterprise with Hyper-V enabled
- ~20GB free RAM (12GB for VMs + host)
- ~200GB free disk
- Windows Server 2022 Evaluation ISO ([download here](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022))

## Quick start

```powershell
# 1. Clone this repo
git clone https://github.com/patrikwm/windows-lab-dsc
cd windows-lab-dsc

# 2. Create the lab network (run as Admin)
.\scripts\01-Create-LabNetwork.ps1

# 3. Create and start the VMs (provide path to ISO)
.\scripts\02-Create-VMs.ps1 -IsoPath "C:\path\to\windows-server-2022.iso"

# 4. Wait for everything to finish (~25-40 minutes)
.\scripts\03-Wait-ForInstall.ps1
```

That's it. Three VMs running, domain configured, users created.

## Test users

| User | Password | mobile (AD) | pager (AD) | Purpose |
|------|----------|-------------|------------|---------|
| testuser | P@ssw0rd123 | +15551234567 | — | Phone-based auth |
| tokenuser | P@ssw0rd123 | ubbc06434510 | AI0877754540 | Hardware token auth |
| assisteduser | P@ssw0rd123 | +15559876543 | — | Assisted/approval auth |
| nofactoruser | P@ssw0rd123 | — | — | No MFA method (error testing) |

Admin: `labadmin` / `ChangeMe!2024#Secure`

## RDP access

```powershell
mstsc /v:10.0.0.10   # DC (LAB\labadmin)
mstsc /v:10.0.0.20   # Client (LAB\testuser or LAB\labadmin)
mstsc /v:10.0.0.30   # Standalone (labadmin)
```

## How it works

1. **01-Create-LabNetwork.ps1** creates a NAT-based Hyper-V internal switch (10.0.0.0/24)
2. **02-Create-VMs.ps1** creates Gen2 VMs with the Windows ISO + per-VM autounattend.xml
3. Each VM's autounattend installs Windows unattended, configures static IP, enables WinRM/RDP
4. After first boot, a **bootstrap script** pulls DSC configs from this GitHub repo
5. DSC applies the role-specific configuration (DC promotion, domain join, user creation, etc.)

## Customization

Edit `dsc/ConfigData.psd1` to change:
- Domain name and NetBIOS name
- Passwords
- Test users and their AD attributes
- IP addresses

## Teardown

```powershell
.\scripts\Teardown-Lab.ps1   # Removes all VMs, disks, network
```

## Network diagram

```
┌─────────────────────────────────────────────┐
│ Windows Host (10.0.0.1)                     │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  ��� LAB-DC   │  │ LAB-     │  │ LAB-      │ │
│  │          │  │ CLIENT   │  │STANDALONE │ │
│  │ 10.0.0.10│  │ 10.0.0.20│  │ 10.0.0.30 │ │
│  └────┬─────┘  └────┬─────┘  └─────┬─────┘ │
│       │              │              │       │
│  ─────┴──────────────┴──────────────┴─────  │
│            WinLab Switch (NAT)           │
│                    │                        │
│              ┌─────┴─────┐                  │
│              │ NetNat    │                  │
│              │ → Internet│                  │
│              └───────────┘                  │
└─────────────────────────────────────────────┘
```
