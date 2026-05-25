# fix-vpn-connectivity.ps1
# Run this as Administrator on the Windows EC2
# Fixes common AnyConnect VPN issues on AWS EC2

Write-Host "=== Applying VPN connectivity fixes ===" -ForegroundColor Cyan

# 1. Add hosts file entries for bank VPN gateways
# Maps .local private hostnames to their public-facing IPs
Write-Host "[1] Adding VPN hosts to C:\Windows\System32\drivers\etc\hosts..."
$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$entries = @(
    "13.248.169.48   ISEPSN-HO1.eab.bank.local",
    "13.248.169.48   ISEPSN-HO2.eab.bank.local",
    "13.248.169.48   hq-psn01.eab.bank.local",
    "13.248.169.48   hq-psn02.eab.bank.local",
    "76.223.54.146   dr-psn01.eab.bank.local",
    "76.223.54.146   dr-psn02.eab.bank.local",
    "76.223.54.146   ISE-PSN-DR01.eab.bank.local",
    "76.223.54.146   ISE-PSN-DR02.eab.bank.local"
)
foreach ($entry in $entries) {
    $host = ($entry -split "\s+")[1]
    $content = Get-Content $hostsFile -Raw
    if ($content -notmatch [regex]::Escape($host)) {
        Add-Content -Path $hostsFile -Value $entry
        Write-Host "  Added: $entry" -ForegroundColor Green
    } else {
        Write-Host "  Already exists: $host" -ForegroundColor Yellow
    }
}

# 2. Set MTU to 1350 on all adapters (fixes fragmentation on AWS/cloud VMs)
Write-Host "[2] Setting MTU to 1350 on all network adapters..."
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
foreach ($adapter in $adapters) {
    netsh interface ipv4 set subinterface "$($adapter.Name)" mtu=1350 store=persistent
    Write-Host "  MTU=1350 set on: $($adapter.Name)" -ForegroundColor Green
}

# 3. Disable Windows Firewall completely (EC2 SG handles it)
Write-Host "[3] Disabling Windows Firewall..."
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Write-Host "  Windows Firewall disabled" -ForegroundColor Green

# 4. Ensure all VPN-related ports are allowed
Write-Host "[4] Adding firewall rules for VPN ports (in case re-enabled)..."
$vpnPorts = @(443, 8443, 8905, 500, 4500, 1194)
foreach ($port in $vpnPorts) {
    New-NetFirewallRule -DisplayName "VPN-TCP-$port" -Direction Outbound `
        -Protocol TCP -RemotePort $port -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "VPN-UDP-$port" -Direction Outbound `
        -Protocol UDP -RemotePort $port -Action Allow -ErrorAction SilentlyContinue | Out-Null
}
Write-Host "  VPN ports allowed" -ForegroundColor Green

# 5. Disable IPv6 (can cause AnyConnect routing issues)
Write-Host "[5] Disabling IPv6..."
Get-NetAdapter | ForEach-Object {
    Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
}
Write-Host "  IPv6 disabled" -ForegroundColor Green

# 6. Flush DNS cache
Write-Host "[6] Flushing DNS cache..."
ipconfig /flushdns | Out-Null
Write-Host "  DNS cache flushed" -ForegroundColor Green

# 7. Test connectivity to VPN gateways
Write-Host ""
Write-Host "=== Testing connectivity to VPN gateways ===" -ForegroundColor Cyan
$targets = @(
    @{Host="ISEPSN-HO1.eab.bank.local"; Port=8443},
    @{Host="ISEPSN-HO2.eab.bank.local"; Port=8443},
    @{Host="hq-psn01.eab.bank.local";   Port=8443},
    @{Host="hq-psn02.eab.bank.local";   Port=8443},
    @{Host="caevpn.eabank.com";          Port=443}
)
foreach ($t in $targets) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect($t.Host, $t.Port)
        Write-Host "  OPEN:   $($t.Host):$($t.Port)" -ForegroundColor Green
        $tcp.Close()
    } catch {
        Write-Host "  CLOSED: $($t.Host):$($t.Port)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Done. Now try AnyConnect. ===" -ForegroundColor Cyan
Write-Host "If still failing, try connecting to: caevpn.eabank.com" -ForegroundColor Yellow
Write-Host "instead of the .local hostnames." -ForegroundColor Yellow
