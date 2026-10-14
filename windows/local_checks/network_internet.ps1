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
$WarnLatency   = 300         # ms -> WARN
$CritLatency   = 400         # ms -> CRIT
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

# ---------- Pencatatan ke CSV ----------
$LogFile  = 'C:\ProgramData\checkmk\agent\log\ping_log.csv'
$MaxLogMB = 5     # jika melebihi ini, file dipindah ke ping_log_old.csv

function Write-PingLog {
    param([string]$Jenis, [string]$Target, $Stats, [int]$State)
    try {
        $dir = Split-Path $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt ($MaxLogMB * 1MB))) {
            Move-Item $LogFile ($LogFile -replace '\.csv$', '_old.csv') -Force
        }
        $statusText = switch ($State) { 0 { 'OK' } 1 { 'WARN' } default { 'CRIT' } }
        $row = [pscustomobject]@{
            Waktu      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            PC         = $env:COMPUTERNAME
            Jenis      = $Jenis
            Target     = $Target
            Terkirim   = $Stats.Sent
            Diterima   = $Stats.Recv
            LossPersen = $Stats.Loss
            RataRataMs = $Stats.Avg
            MaksMs     = $Stats.Max
            Status     = $statusText
        }
        for ($i = 0; $i -lt 3; $i++) {
            try {
                $row | Export-Csv -Path $LogFile -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                break
            } catch { Start-Sleep -Milliseconds 300 }
        }
    } catch {}
}

# ---------- Daftar kejadian bermasalah (untuk kolom Details di Checkmk) ----------
# Memakai "\n" literal: Checkmk menjadikannya baris baru di Details.
function Get-ProblemDetail {
    param([string]$Jenis, [string]$Target, [int]$Hours = 24, [int]$MaxList = 10)
    try {
        if (-not (Test-Path $LogFile)) { return '\nRiwayat ping belum tersedia' }
        $since = (Get-Date).AddHours(-$Hours).ToString('yyyy-MM-dd HH:mm:ss')
        $bad = @(Import-Csv -Path $LogFile -ErrorAction Stop | Where-Object {
            $_.Jenis -eq $Jenis -and $_.Target -eq $Target -and $_.Status -ne 'OK' -and $_.Waktu -gt $since
        })
        if ($bad.Count -eq 0) { return "\nTidak ada masalah ping dalam $Hours jam terakhir" }
        $list = @($bad | Sort-Object Waktu -Descending | Select-Object -First $MaxList | ForEach-Object {
            '{0} {1} loss {2}%, rata-rata {3} ms' -f $_.Waktu.Substring(5), $_.Status, $_.LossPersen, $_.RataRataMs
        })
        $more = ''
        if ($bad.Count -gt $MaxList) {
            $more = '\n... dan ' + ($bad.Count - $MaxList) + ' kejadian lain (lihat ping_log.csv)'
        }
        return ("\nBermasalah $($bad.Count) kali dalam $Hours jam terakhir (terbaru dulu):\n" + ($list -join '\n') + $more)
    } catch { return '' }
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
    $name = "Info_Network Internet $t"

    $logState = $state
    if ($s.Recv -eq 0) {
        if ($multi -and $anyReachable) { $logState = 1 } else { $logState = 2 }
    }
    Write-PingLog 'Internet' $t $s $logState
    $detail = Get-ProblemDetail 'Internet' $t

    if ($s.Recv -eq 0) {
        if ($multi -and $anyReachable) {
            # Ada target lain yang masih terjangkau -> kemungkinan hanya target ini bermasalah
            Write-Check 1 $name $metrics "$t tidak merespon, target lain masih terjangkau$detail"
        } else {
            Write-Check 2 $name $metrics "$t tidak terjangkau (koneksi keluar bermasalah)$detail"
        }
    } else {
        Write-Check $state $name $metrics "$t : loss $($s.Loss)%, rata-rata $($s.Avg) ms, maks $($s.Max) ms$detail"
    }
}
