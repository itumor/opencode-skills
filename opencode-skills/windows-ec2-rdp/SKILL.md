---
name: windows-ec2-rdp
description: Windows Server EC2 on AWS — launch, connect via RDP from Mac, WinRM remote PowerShell, stop/start to save cost. Use when asked to set up a Windows VM, connect via Remote Desktop, run PowerShell remotely, or manage Windows EC2 instances.
---

# Windows EC2 RDP — Global Reference

## Terraform Module

Path: `/Users/eramadan/openscript/nextgenopen/terraform/windows-ec2-rdp/`

```bash
cd /Users/eramadan/openscript/nextgenopen/terraform/windows-ec2-rdp
source ../../.env
MY_IP=$(curl -s https://checkip.amazonaws.com)/32

terraform init
terraform apply -auto-approve \
  -var="admin_cidr=${MY_IP}" \
  -var="instance_type=t3.medium" \
  -var="volume_size_gb=50"

# Get credentials
terraform output -raw public_ip
terraform output -raw rdp_password
```

## Install Microsoft Remote Desktop on Mac

```bash
brew install --cask windows-app
# Then run: open /Applications/Windows\ App.app
```

## Connect via Windows App (Mac)

1. Open **Windows App**
2. `+` → Add PC
3. PC Name: `<public_ip>`
4. Username: `Administrator`
5. Password: from `terraform output -raw rdp_password`
6. Accept cert → Connect

## WinRM Remote PowerShell from Mac

```python
import winrm  # pip3 install pywinrm

session = winrm.Session(
    'IP_ADDRESS',
    auth=('Administrator', 'PASSWORD'),
    transport='ntlm',          # MUST use ntlm, not basic
    server_cert_validation='ignore'
)
result = session.run_ps('Get-Service | Select-Object Name,Status')
print(result.std_out.decode('utf-8', errors='ignore'))
```

Port 5985 must be open. Check: `nc -z -w3 IP 5985 && echo OPEN`

## Scripts

```bash
# Get IP + password
bash scripts/get-rdp-password.sh

# Start stopped instance + get new IP
bash scripts/start-and-connect.sh

# Stop to save cost
bash scripts/stop-instance.sh
```

## Stop/Start Manually

```bash
source /Users/eramadan/openscript/nextgenopen/.env
# Stop
aws ec2 stop-instances --instance-ids INSTANCE_ID
# Start
aws ec2 start-instances --instance-ids INSTANCE_ID
aws ec2 wait instance-running --instance-ids INSTANCE_ID
aws ec2 describe-instances --instance-ids INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

## Bootstrap (auto-installed via user_data)

- Chocolatey, Chrome, VS Code, Git, 7-Zip, Notepad++
- RDP enabled, NLA disabled for dev use
- Check: `C:\bootstrap-complete.txt` exists when done

## Resize Instance

```bash
# Stop first
aws ec2 stop-instances --instance-ids $ID
aws ec2 wait instance-stopped --instance-ids $ID
# Resize
aws ec2 modify-instance-attribute --instance-id $ID --instance-type t3.xlarge
# Start
aws ec2 start-instances --instance-ids $ID
```

## Elastic IP (permanent IP)

```bash
EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
aws ec2 associate-address --instance-id $ID --allocation-id $EIP
# Release when done
aws ec2 release-address --allocation-id $EIP
```

## Cost

| State | Type | Cost |
|-------|------|------|
| Running | t3.medium Windows | ~$0.048/hr |
| Running | t3.large Windows | ~$0.096/hr |
| Stopped | any | ~$0.13/day (EBS 50GB) |
| Elastic IP unattached | — | ~$0.12/day |

## Terminate All Resources

```bash
terraform destroy -auto-approve \
  -var="admin_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```

## AnyConnect VPN on Windows EC2

Key fix — vendor XML must have:
```xml
<WindowsVPNEstablishment>AllowRemoteUsers</WindowsVPNEstablishment>
```
Default `LocalUsersOnly` blocks VPN from RDP sessions.

Also set in `AnyConnectLocalPolicy.xml`:
- `BypassDownloader` → `false`
- `StrictCertificateTrust` → `false`

After editing XML: restart vpnagent service.
