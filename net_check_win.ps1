param(
    [switch]$NoColor,
    [switch]$NoPauseAtEnd,
    [string]$CampusGatewayRegex = $env:NETCHECK_CAMPUS_GATEWAY_REGEX,
    [string]$DnsTestDomain = $(if ($env:NETCHECK_DNS_TEST_DOMAIN) { $env:NETCHECK_DNS_TEST_DOMAIN } else { "google.com" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "2.1"
$TargetIcmp = "8.8.8.8"
$TargetTcpHost = "1.1.1.1"
$TargetTcpPort = 443
$MaxHops = 4

function Pause-IfNeeded {
    if ($NoPauseAtEnd) {
        return
    }
    if (-not [Environment]::UserInteractive) {
        return
    }
    try {
        [void]$Host.UI.RawUI
        [void](Read-Host "Press Enter to close this window")
    } catch {
    }
}

function Exit-Script {
    param(
        [int]$Code
    )
    Pause-IfNeeded
    exit $Code
}

function Write-ResultAndExit {
    param(
        [int]$Code,
        [ValidateSet("INFO", "OK", "WARN", "FAIL")]
        [string]$Level,
        [string]$Summary,
        [string]$NextStep = ""
    )

    Write-Host "--------------------------------------------"
    Write-Status $Level ("RESULT: {0}" -f $Summary)
    if ($NextStep) {
        Write-Status INFO ("NEXT STEP: {0}" -f $NextStep)
    }
    Exit-Script $Code
}

function Write-Status {
    param(
        [ValidateSet("INFO", "OK", "WARN", "FAIL")]
        [string]$Level,
        [string]$Message
    )

    $prefix = "[{0}]" -f $Level.PadRight(4)
    if ($NoColor) {
        Write-Host "$prefix $Message"
        return
    }

    $color = switch ($Level) {
        "INFO" { "Cyan" }
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Test-PersonalRouterGateway {
    param(
        [string]$Gateway,
        [string]$CampusRegex
    )

    if ($CampusRegex) {
        try {
            if ($Gateway -match $CampusRegex) {
                return $false
            }
        } catch {
        }
    }

    $commonRouters = @("192.168.0.1", "192.168.1.1", "192.168.50.1", "10.0.0.1", "10.0.1.1")
    return ($commonRouters -contains $Gateway)
}

function Get-DefaultGateway {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            return $route.NextHop
        }
    } catch {
    }

    try {
        $line = route print 0.0.0.0 | Select-String "^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)"
        if ($line) {
            return $line.Matches[0].Groups[1].Value
        }
    } catch {
    }

    return $null
}

function Test-DnsResolution {
    param(
        [string]$Domain
    )

    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
            Resolve-DnsName -Name $Domain -Type A -ErrorAction Stop | Out-Null
            return 0
        } catch {
            return 1
        }
    }

    if (Get-Command nslookup -ErrorAction SilentlyContinue) {
        try {
            $output = nslookup $Domain 2>$null
            if ($LASTEXITCODE -eq 0 -and ($output -match "Address")) {
                return 0
            }
            return 1
        } catch {
            return 1
        }
    }

    return 2
}

function Test-TcpPort {
    param(
        [string]$Host,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect($Host, $Port, $null, $null)
        $connected = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $connected) {
            $client.Close()
            return $false
        }
        $client.EndConnect($asyncResult) | Out-Null
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host ("   WINDOWS NETWORK DIAGNOSTICS v{0}" -f $ScriptVersion) -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$gateway = Get-DefaultGateway
if (-not $gateway) {
    Write-ResultAndExit -Code 10 -Level FAIL -Summary "No active network connection found." -NextStep "Connect to campus Wi-Fi or Ethernet, then run again."
}
Write-Status OK ("LOCAL: Connected. Gateway: {0}" -f $gateway)

$routerSuspect = Test-PersonalRouterGateway -Gateway $gateway -CampusRegex $CampusGatewayRegex
if ($routerSuspect) {
    Write-Status WARN ("Gateway looks like a personal router ({0}). Check WAN cable to wall port." -f $gateway)
}

if (-not (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
    Write-ResultAndExit -Code 11 -Level FAIL -Summary "Connected, but cannot reach your gateway/router." -NextStep "Check room cable, wall port, Wi-Fi signal, or router power."
}
Write-Status OK "LINK: Gateway reachable."

$icmpOk = Test-Connection -ComputerName $TargetIcmp -Count 1 -Quiet -ErrorAction SilentlyContinue
$tcpOk = Test-TcpPort -Host $TargetTcpHost -Port $TargetTcpPort -TimeoutMs 1500

if ($icmpOk -or $tcpOk) {
    Write-Status OK "INTERNET: Reachability test passed."
    if (-not $icmpOk -and $tcpOk) {
        Write-Status WARN "ICMP appears filtered, but TCP/443 is working."
    }

    $dnsState = Test-DnsResolution -Domain $DnsTestDomain
    switch ($dnsState) {
        0 { Write-ResultAndExit -Code 0 -Level OK -Summary "Internet and website name lookup (DNS) are working." -NextStep "You should be able to browse normally." }
        1 { Write-ResultAndExit -Code 12 -Level WARN -Summary "Internet is up, but DNS lookup is failing." -NextStep "Set DNS to Automatic, or try 1.1.1.1 / 8.8.8.8." }
        default { Write-ResultAndExit -Code 0 -Level OK -Summary "Internet is working." -NextStep "DNS check tool is not available on this device." }
    }
}

Write-Status WARN "INTERNET: Public reachability failed. Running quick path check."
if (-not (Get-Command tracert -ErrorAction SilentlyContinue)) {
    if ($routerSuspect) {
        Write-ResultAndExit -Code 30 -Level FAIL -Summary "Your router responds, but internet is still down." -NextStep "Check WAN cable to wall port and router internet settings."
    }
    Write-ResultAndExit -Code 30 -Level FAIL -Summary "Gateway responds, but internet is still down." -NextStep "Likely room uplink or campus backend issue. Contact campus IT."
}

$traceLines = tracert -d -h $MaxHops -w 800 $TargetIcmp 2>$null
$hop1 = $traceLines | Where-Object { $_ -match "^\s*1\s+" } | Select-Object -First 1
$hop2 = $traceLines | Where-Object { $_ -match "^\s*2\s+" } | Select-Object -First 1

if (-not $hop1 -or $hop1 -match "\*\s+\*\s+\*") {
    if ($routerSuspect) {
        Write-ResultAndExit -Code 20 -Level FAIL -Summary "Traffic fails near your router/room network." -NextStep "Check router WAN cable, wall port, and reboot router."
    }
    Write-ResultAndExit -Code 20 -Level FAIL -Summary "Traffic fails near your room connection." -NextStep "Check cable, wall port, or local Wi-Fi/Ethernet setup."
}

if (-not $hop2 -or $hop2 -match "\*\s+\*\s+\*") {
    if ($routerSuspect) {
        Write-ResultAndExit -Code 21 -Level FAIL -Summary "Your router is reachable, but its uplink likely has a problem." -NextStep "Reconnect WAN cable from router to wall and test again."
    }
    Write-ResultAndExit -Code 21 -Level FAIL -Summary "Local gateway works, but campus/backend uplink may be down." -NextStep "Report this to campus IT with this result."
}

Write-ResultAndExit -Code 22 -Level WARN -Summary "Local network is okay; issue is likely upstream (ISP/remote service)." -NextStep "Wait a bit or try another external site."
