param(
    [switch]$NoColor,
    [switch]$NoPauseAtEnd,
    [string]$CampusGatewayRegex = $env:NETCHECK_CAMPUS_GATEWAY_REGEX,
    [string]$DnsTestDomain = $(if ($env:NETCHECK_DNS_TEST_DOMAIN) { $env:NETCHECK_DNS_TEST_DOMAIN } else { "google.com" }),
    [switch]$Track,
    [string]$TrackMac = $(if ($env:NETCHECK_TRACK_TARGET) { $env:NETCHECK_TRACK_TARGET } else { "" }),
    [double]$TrackIntervalSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "2.2"
$TargetIcmp = "8.8.8.8"
$TargetTcpHost = "1.1.1.1"
$TargetTcpPort = 443
$MaxHops = 4
$TrackWindow = 5
$TrackMinStep = 3

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

    if ($Gateway -match "^192\.168\.\d{1,3}\.\d{1,3}$") {
        return $true
    }
    if ($Gateway -match "^172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}$") {
        return $true
    }

    $commonRouters = @("192.168.0.1", "192.168.1.1", "192.168.50.1", "10.0.0.1", "10.0.1.1")
    return ($commonRouters -contains $Gateway)
}

function Normalize-Mac {
    param(
        [string]$Mac
    )

    if (-not $Mac) {
        return $null
    }

    $clean = $Mac.Trim().ToUpper().Replace("-", ":")
    if ($clean -match "^([0-9A-F]{2}:){5}[0-9A-F]{2}$") {
        return $clean
    }
    return $null
}

function Get-ConnectedBssid {
    if (-not (Get-Command netsh -ErrorAction SilentlyContinue)) {
        return $null
    }

    $output = netsh wlan show interfaces 2>$null
    foreach ($line in $output) {
        if ($line -match "^\s*BSSID\s*:\s*([0-9A-Fa-f:-]{17})\s*$") {
            return (Normalize-Mac -Mac $matches[1])
        }
    }
    return $null
}

function Get-SignalForBssid {
    param(
        [string]$TargetMac
    )

    $normalized = Normalize-Mac -Mac $TargetMac
    if (-not $normalized) {
        return $null
    }

    $scan = netsh wlan show networks mode=bssid 2>$null
    $lines = $scan -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*BSSID\s+\d+\s*:\s*([0-9A-Fa-f:-]{17})\s*$") {
            $candidate = Normalize-Mac -Mac $matches[1]
            if ($candidate -ne $normalized) {
                continue
            }

            for ($j = 1; $j -le 6 -and ($i + $j) -lt $lines.Count; $j++) {
                if ($lines[$i + $j] -match "^\s*Signal\s*:\s*(\d+)%\s*$") {
                    return [int]$matches[1]
                }
            }
        }
    }

    return $null
}

function Start-WifiTracker {
    param(
        [string]$Target,
        [double]$IntervalSeconds
    )

    if (-not (Get-Command netsh -ErrorAction SilentlyContinue)) {
        Write-ResultAndExit -Code 52 -Level FAIL -Summary "Wi-Fi tracker requires netsh, but netsh is missing." -NextStep "Run this on standard Windows with WLAN tools enabled."
    }

    if ($IntervalSeconds -lt 1) {
        Write-Status WARN "Windows Wi-Fi scanning is throttled. Using 1 second minimum interval."
        $IntervalSeconds = 1
    }

    $normalizedTarget = Normalize-Mac -Mac $Target
    if (-not $normalizedTarget) {
        $normalizedTarget = Get-ConnectedBssid
    }

    if (-not $normalizedTarget) {
        Write-ResultAndExit -Code 53 -Level FAIL -Summary "No tracker target selected." -NextStep "Run with -Track -TrackMac AA:BB:CC:DD:EE:FF or connect to target Wi-Fi first."
    }

    Write-Status INFO ("TRACKER: Monitoring BSSID {0}" -f $normalizedTarget)
    Write-Status INFO ("TRACKER: Sampling every {0}s (moving avg window: {1}, step threshold: {2})" -f $IntervalSeconds, $TrackWindow, $TrackMinStep)
    Write-Status INFO "TRACKER: Press Ctrl+C to stop."

    $samples = New-Object System.Collections.Generic.List[int]
    $previousAverage = $null
    $trendState = "STABLE"
    $trendStreak = 0

    while ($true) {
        $signal = Get-SignalForBssid -TargetMac $normalizedTarget
        if ($null -eq $signal) {
            Write-Host ("`r[WARN] Signal not visible for {0}. Move and rescan...                     " -f $normalizedTarget) -NoNewline
            Start-Sleep -Milliseconds ([Math]::Round($IntervalSeconds * 1000))
            continue
        }

        [void]$samples.Add([int]$signal)
        while ($samples.Count -gt $TrackWindow) {
            $samples.RemoveAt(0)
        }

        $sum = 0
        foreach ($sample in $samples) {
            $sum += $sample
        }
        $average = [int][Math]::Round($sum / $samples.Count)
        $direction = "STABLE"
        $hint = "HOLD"

        if ($null -ne $previousAverage) {
            $delta = $average - $previousAverage
            if ($delta -ge $TrackMinStep) {
                $direction = "CLOSER"
            } elseif ($delta -le (-1 * $TrackMinStep)) {
                $direction = "AWAY"
            }
        }

        if ($direction -eq $trendState -and $direction -ne "STABLE") {
            $trendStreak++
        } else {
            $trendState = $direction
            $trendStreak = 1
        }

        if ($direction -eq "CLOSER" -and $trendStreak -ge 2) {
            $hint = "MOVING CLOSER"
        } elseif ($direction -eq "AWAY" -and $trendStreak -ge 2) {
            $hint = "MOVING AWAY"
        }

        $barLen = [Math]::Min([Math]::Floor($signal / 2), 50)
        $bar = ("#" * $barLen).PadRight(50, " ")
        Write-Host ("`rSignal: [{0}] {1,3}%  Avg:{2,3}%  Trend:{3,-13} Target:{4}" -f $bar, $signal, $average, $hint, $normalizedTarget) -NoNewline

        $previousAverage = $average
        Start-Sleep -Milliseconds ([Math]::Round($IntervalSeconds * 1000))
    }
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
        [string]$Hostname,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect($Hostname, $Port, $null, $null)
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

if ($Track) {
    Start-WifiTracker -Target $TrackMac -IntervalSeconds $TrackIntervalSeconds
    Write-Host ""
    Exit-Script 0
}

$gateway = Get-DefaultGateway
if (-not $gateway) {
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        try {
            $up = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
            if ($up) {
                Write-ResultAndExit -Code 15 -Level FAIL -Summary "Cable connected, but no IP address received from network." -NextStep "This wall port is likely disabled (dead) or blocked by CCN. Try a different port if that doesn't work fill complaint form."
            }
        } catch {}
    }
    Write-ResultAndExit -Code 10 -Level FAIL -Summary "No active network connection found." -NextStep "Connect to campus Wi-Fi or Ethernet, then run again."
}
Write-Status OK ("LOCAL: Connected. Gateway: {0}" -f $gateway)

$routerSuspect = Test-PersonalRouterGateway -Gateway $gateway -CampusRegex $CampusGatewayRegex
if ($routerSuspect) {
    Write-Status WARN ("Gateway looks like a personal router path ({0}). Check uplink/WAN connection." -f $gateway)
}

if (-not (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
    Write-ResultAndExit -Code 11 -Level FAIL -Summary "Connected, but cannot reach your gateway/router." -NextStep "Check room cable, wall port, Wi-Fi signal, or router power."
}
Write-Status OK "LINK: Gateway reachable."

$icmpOk = Test-Connection -ComputerName $TargetIcmp -Count 1 -Quiet -ErrorAction SilentlyContinue
$tcpOk = Test-TcpPort -Hostname $TargetTcpHost -Port $TargetTcpPort -TimeoutMs 1500

if ($icmpOk -or $tcpOk) {
    Write-Status OK "INTERNET: Reachability test passed."
    if (-not $icmpOk -and $tcpOk) {
        Write-Status WARN "ICMP appears filtered, but TCP/443 is working."
    }
    if ($routerSuspect) {
        Write-Status WARN "Traffic is passing through a personal router gateway."
    }

    $dnsState = Test-DnsResolution -Domain $DnsTestDomain
    switch ($dnsState) {
        0 { Write-ResultAndExit -Code 0 -Level OK -Summary "Internet and website name lookup (DNS) are working." -NextStep "You should be able to browse normally." }
        1 { Write-ResultAndExit -Code 12 -Level WARN -Summary "Internet is up, but DNS lookup is failing." -NextStep "Set DNS to Automatic, or try 1.1.1.1 / 8.8.8.8." }
        default { Write-ResultAndExit -Code 0 -Level OK -Summary "Internet is working." -NextStep "DNS check tool is not available on this device." }
    }
}

Write-Status WARN "INTERNET: Public reachability failed. Running quick path check."
if ($routerSuspect) {
    Write-Status WARN "Personal router path suspected. Verifying whether failure is local uplink vs upstream."
}
if (-not (Get-Command tracert -ErrorAction SilentlyContinue)) {
    if ($routerSuspect) {
        Write-ResultAndExit -Code 30 -Level FAIL -Summary "Your router responds, but internet is still down." -NextStep "Check WAN cable to wall port and router internet settings."
    }
    Write-ResultAndExit -Code 30 -Level FAIL -Summary "Gateway responds, but internet is still down." -NextStep "Likely room uplink or campus backend issue. Contact CCN and fill complaint form."
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
    Write-ResultAndExit -Code 21 -Level FAIL -Summary "Local gateway works, but campus/backend uplink may be down." -NextStep "Report this to CCN and fill complaint form."
}

if ($routerSuspect) {
    Write-ResultAndExit -Code 22 -Level WARN -Summary "Personal router detected. Issue is likely on that router uplink or its upstream path." -NextStep "Bypass router once, then reconnect WAN/uplink and test again."
}
Write-ResultAndExit -Code 22 -Level WARN -Summary "Local network is okay; issue is likely upstream (ISP/remote service)." -NextStep "Wait a bit or try another external site."
