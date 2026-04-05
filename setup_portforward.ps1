# Sebang AMR Port Forwarding Setup
# Run as Administrator
# Requires: VPN connected, 10.10.150.119 reachable

$SERVER = "10.10.150.119"

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Sebang AMR Port Forwarding Setup" -ForegroundColor Cyan
Write-Host "  Server: $SERVER" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# Clear existing rules
Write-Host "`n[1] Reset existing portproxy rules..." -ForegroundColor Yellow
netsh interface portproxy reset
Write-Host "    Done." -ForegroundColor Green

function Add-Proxy($lp, $cp, $label) {
    netsh interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 listenport=$lp `
        connectaddress=$SERVER connectport=$cp | Out-Null
    Write-Host "    $lp -> ${SERVER}:$cp  [$label]" -ForegroundColor Green
}

# [A] Server / Dashboard
Write-Host "`n[2] Server / Dashboard" -ForegroundColor Yellow
Add-Proxy 10080 80    "CROMS Web"
Add-Proxy 10022 10022 "Server SSH"
Add-Proxy 9090  9090  "AMR Dashboard"
Add-Proxy 8083  8083  "MQTT WebSocket"
Add-Proxy 18083 18083 "EMQX Console"
netsh advfirewall firewall delete rule name="AMR-Server" | Out-Null
netsh advfirewall firewall add rule name="AMR-Server" protocol=TCP dir=in localport="10080,10022,9090,8083,18083" action=allow | Out-Null

# [B] Robot SSH (9101~9113)
Write-Host "`n[3] Robot SSH (9101-9113)" -ForegroundColor Yellow
for ($i = 1; $i -le 13; $i++) {
    $port = 9100 + $i
    Add-Proxy $port $port ("Robot-SSH sebang" + $i.ToString("D3"))
}
netsh advfirewall firewall delete rule name="AMR-RobotSSH" | Out-Null
netsh advfirewall firewall add rule name="AMR-RobotSSH" protocol=TCP dir=in localport="9101-9113" action=allow | Out-Null

# [C] MOXA Web UI (9201~9213)
Write-Host "`n[4] MOXA Web UI (9201-9213)" -ForegroundColor Yellow
for ($i = 1; $i -le 13; $i++) {
    $port = 9200 + $i
    Add-Proxy $port $port ("MOXA-Web sebang" + $i.ToString("D3"))
}
netsh advfirewall firewall delete rule name="AMR-MoxaWeb" | Out-Null
netsh advfirewall firewall add rule name="AMR-MoxaWeb" protocol=TCP dir=in localport="9201-9213" action=allow | Out-Null

# [D] AP Web UI (9301~9315)
Write-Host "`n[5] AP Web UI (9301-9315)" -ForegroundColor Yellow
for ($i = 1; $i -le 15; $i++) {
    $port = 9300 + $i
    Add-Proxy $port $port ("AP-" + $i.ToString("D2") + " Web")
}
netsh advfirewall firewall delete rule name="AMR-APWeb" | Out-Null
netsh advfirewall firewall add rule name="AMR-APWeb" protocol=TCP dir=in localport="9301-9315" action=allow | Out-Null

# [E] Switch Web UI (9401~9404)
Write-Host "`n[6] Switch Web UI (9401-9404)" -ForegroundColor Yellow
Add-Proxy 9401 9401 "SW-Main-01 Web"
Add-Proxy 9402 9402 "SW-PoE-01 Web"
Add-Proxy 9403 9403 "SW-PoE-02 Web"
Add-Proxy 9404 9404 "SW-PoE-03 Web"
netsh advfirewall firewall delete rule name="AMR-SwitchWeb" | Out-Null
netsh advfirewall firewall add rule name="AMR-SwitchWeb" protocol=TCP dir=in localport="9401-9404" action=allow | Out-Null

# Show result
Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host "  All portproxy rules:" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
netsh interface portproxy show all

$myIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -like "10.10.*" -or $_.IPAddress -like "172.16.*"
} | Select-Object -First 1).IPAddress

Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host "  Access Info  (My VPN IP: $myIp)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  CROMS 관제       : http://${myIp}:10080/monitoring/control" -ForegroundColor White
Write-Host "  AMR Dashboard    : http://${myIp}:9090" -ForegroundColor White
Write-Host "  Server SSH       : ssh -p 10022 clobot@${myIp}" -ForegroundColor White
Write-Host "  EMQX Console     : http://${myIp}:18083  (admin/public)" -ForegroundColor White
Write-Host "  Robot SSH AMR-01 : ssh -p 9101 thira@${myIp}" -ForegroundColor White
Write-Host "  MOXA Web  AMR-01 : http://${myIp}:9201" -ForegroundColor White
Write-Host "  AP-01 Web        : http://${myIp}:9301  (* server setup needed)" -ForegroundColor DarkYellow
Write-Host "  SW-Main Web      : http://${myIp}:9401  (* server setup needed)" -ForegroundColor DarkYellow
Write-Host ""

pause
