# ==========================================================
# network_internet.ps1 - Checkmk Local Check (Windows)
# Cek koneksi KELUAR: ping ke target (default 192.168.122.10).
# Tiap target menjadi satu service: "Network Internet <target>"
# Letakkan di: C:\ProgramData\checkmk\agent\local\
# ==========================================================

$ErrorActionPreference = 'SilentlyContinue'

# ---------- Pengaturan ----------
$InternetHosts = @('192.168.122.10')   # target ping koneksi keluar (boleh lebih dari satu)
$PingCount     = 4           # jumlah ping per target
$WarnLoss      = 25          # % packet loss -> WARN
$CritLoss      = 50          # % packet loss -> CRIT
$WarnLatency   = 100         # ms -> WARN
$CritLatency   = 300         # ms -> CRIT
# --------------------------------

function Write-Check {
    param([int]$State, [string]$Name, [string]$Metrics, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Metrics)) { $Metrics = '-' }
    Write-Output ('{0} "{1}" {2} {3}' -f $State, $Name, $Metrics, $Text)
}

function Get-PingStats {
    param([string]$Target, [int]$Count = 4)
    $ping  = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, 1000)
            if ($r.Status -eq 'Success') { $times += [int]$r.RoundtripTime }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    $recv = $times.Count
    $avg = 0; $max = 0
    if ($recv -gt 0) {
        $avg = [math]::Round(($times | Measure-Object -Average).Average)
        $max = ($times | Measure-Object -Maximum).Maximum
    }
    [pscustomobject]@{
        Sent = $Count
        Recv = $recv
        Loss = [math]::Round((($Count - $recv) / $Count) * 100)
        Avg  = $avg
        Max  = $max
    }
}

function Get-PingState {
    param($Stats)
    if ($Stats.Recv -eq 0) { return 2 }
    if ($Stats.Loss -ge $CritLoss -or $Stats.Avg -ge $CritLatency) { return 2 }
    if ($Stats.Loss -ge $WarnLoss -or $Stats.Avg -ge $WarnLatency) { return 1 }
    return 0
}

# ---------- Ping semua target ----------
$results = @()
foreach ($t in $InternetHosts) {
    $results += [pscustomobject]@{ Target = $t; Stats = (Get-PingStats -Target $t -Count $PingCount) }
}
$anyReachable = (@($results | Where-Object { $_.Stats.Recv -gt 0 })).Count -gt 0
$multi = ($InternetHosts.Count -gt 1)

foreach ($r in $results) {
    $s = $r.Stats
    $t = $r.Target
    $state = Get-PingState $s
    $metrics = "loss=$($s.Loss);$WarnLoss;$CritLoss;0;100|rtt=$($s.Avg);$WarnLatency;$CritLatency"
    $name = "Network Internet $t"

    if ($s.Recv -eq 0) {
        if ($multi -and $anyReachable) {
            # Ada target lain yang masih terjangkau -> kemungkinan hanya target ini bermasalah
            Write-Check 1 $name $metrics "$t tidak merespon, target lain masih terjangkau"
        } else {
            Write-Check 2 $name $metrics "$t tidak terjangkau (koneksi keluar bermasalah)"
        }
    } else {
        Write-Check $state $name $metrics "$t : loss $($s.Loss)%, rata-rata $($s.Avg) ms, maks $($s.Max) ms"
    }
}
